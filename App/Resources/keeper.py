#!/usr/bin/env python3
"""Keep or clear a simulated Core Location position on one trusted iPhone."""

from __future__ import annotations

import argparse
import asyncio
import errno
import fcntl
import json
import logging
import math
import os
import signal
import time
from contextlib import suppress, asynccontextmanager
from logging.handlers import RotatingFileHandler
from pathlib import Path

class DeviceNotFoundError(Exception):
    pass

class NoDeviceConnectedError(Exception):
    pass


APP_SUPPORT_PATH = Path.home() / "Library/Application Support/Pinshift"
CONFIG_PATH = APP_SUPPORT_PATH / "config.json"
STATUS_PATH = APP_SUPPORT_PATH / "status.json"
APP_LIVENESS_LOCK_PATH = APP_SUPPORT_PATH / "gui-liveness.lock"
LOG_PATH = Path(
    os.environ.get(
        "PINSHIFT_LOG_PATH",
        Path.home() / "Library/Logs/Pinshift.log",
    )
)
SET_TIMEOUT_SECONDS = 20
CONNECT_TIMEOUT_SECONDS = 30
REMOTE_BONJOUR_TIMEOUT_SECONDS = 12
WAKE_CHECK_SECONDS = 0.25
STOP_GRACE_SECONDS = 12
APP_HEARTBEAT_TIMEOUT_SECONDS = 5 * 60
APP_HEARTBEAT_FUTURE_TOLERANCE_SECONDS = 60


class ConfigurationError(ValueError):
    pass


class AmbiguousDeviceError(RuntimeError):
    pass


class AppCleanupLease:
    def __init__(self, descriptor: int):
        self.descriptor = descriptor

    def close(self) -> None:
        if self.descriptor < 0:
            return
        with suppress(OSError):
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
        with suppress(OSError):
            os.close(self.descriptor)
        self.descriptor = -1

    def __del__(self):
        self.close()


LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        RotatingFileHandler(
            LOG_PATH,
            maxBytes=2 * 1024 * 1024,
            backupCount=2,
            encoding="utf-8",
        )
    ],
)
logger = logging.getLogger("pinshift-keeper")


def load_config(path: Path | None = None) -> dict:
    path = path or CONFIG_PATH
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as error:
        raise ConfigurationError(f"Cannot read a valid Pinshift configuration: {error}") from error

    required = (
        "cityID",
        "cityName",
        "country",
        "latitude",
        "longitude",
        "retrySeconds",
        "refreshSeconds",
        "requestID",
    )
    missing = [key for key in required if key not in data]
    if missing:
        raise ConfigurationError(f"Missing configuration fields: {', '.join(missing)}")

    try:
        latitude = float(data["latitude"])
        longitude = float(data["longitude"])
        retry_seconds = max(1, min(60, int(data["retrySeconds"])))
        refresh_seconds = max(2, min(300, int(data["refreshSeconds"])))
    except (TypeError, ValueError) as error:
        raise ConfigurationError(f"Invalid coordinate or interval: {error}") from error

    if not math.isfinite(latitude) or not -90 <= latitude <= 90:
        raise ConfigurationError("Latitude must be a finite number between -90 and 90")
    if not math.isfinite(longitude) or not -180 <= longitude <= 180:
        raise ConfigurationError("Longitude must be a finite number between -180 and 180")

    simulation_enabled = data.get("simulationEnabled", True)
    if not isinstance(simulation_enabled, bool):
        raise ConfigurationError("simulationEnabled must be a boolean")

    app_heartbeat_at = data.get("appHeartbeatAt")
    if app_heartbeat_at is not None:
        try:
            app_heartbeat_at = float(app_heartbeat_at)
        except (TypeError, ValueError) as error:
            raise ConfigurationError("appHeartbeatAt must be a timestamp") from error
        if not math.isfinite(app_heartbeat_at):
            raise ConfigurationError("appHeartbeatAt must be a finite timestamp")

    return {
        **data,
        "latitude": latitude,
        "longitude": longitude,
        "retrySeconds": retry_seconds,
        "refreshSeconds": refresh_seconds,
        "simulationEnabled": simulation_enabled,
        "appHeartbeatAt": app_heartbeat_at,
        "requestID": str(data["requestID"]),
    }


def heartbeat_is_fresh(config: dict, now: float | None = None) -> bool:
    heartbeat = config.get("appHeartbeatAt")
    if heartbeat is None:
        return False
    now = time.time() if now is None else now
    age = now - float(heartbeat)
    return -APP_HEARTBEAT_FUTURE_TOLERANCE_SECONDS <= age <= APP_HEARTBEAT_TIMEOUT_SECONDS


def acquire_app_cleanup_lease(
    path: Path | None = None,
) -> tuple[str, AppCleanupLease | None]:
    path = path or APP_LIVENESS_LOCK_PATH
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_CLOEXEC", 0)
        descriptor = os.open(path, flags, 0o600)
        os.chmod(path, 0o600)
    except OSError as error:
        logger.warning("Could not probe Pinshift GUI liveness: %s", error)
        return "unknown", None

    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        os.close(descriptor)
        if error.errno in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
            return "alive", None
        logger.warning("Could not lock Pinshift GUI liveness file: %s", error)
        return "unknown", None
    return "dead", AppCleanupLease(descriptor)


def simulation_request_decision(
    config: dict,
    cleanup_lease: AppCleanupLease | None = None,
    now: float | None = None,
) -> tuple[bool, AppCleanupLease | None]:
    if not config.get("simulationEnabled", False):
        return False, cleanup_lease
    if cleanup_lease is not None:
        return False, cleanup_lease
    if heartbeat_is_fresh(config, now=now):
        return True, None

    liveness, cleanup_lease = acquire_app_cleanup_lease()
    if liveness == "dead":
        return False, cleanup_lease
    # An unknown lock result is not proof that the GUI died. Preserve the
    # explicit Start request and retry instead of clearing a live simulation.
    return True, None


def config_version(path: Path | None = None) -> int:
    path = path or CONFIG_PATH
    try:
        return path.stat().st_mtime_ns
    except OSError:
        return 0


def read_status(path: Path | None = None) -> dict:
    path = path or STATUS_PATH
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def forced_shutdown_exit_code(status: dict | None = None) -> int:
    status = read_status() if status is None else status
    if status.get("phase") == "cleared" and not status.get("simulationMayBeActive", True):
        return 0
    return 75


def write_status(
    phase: str,
    request_id: str,
    simulation_may_be_active: bool,
    device_udid: str | None,
    message: str | None = None,
    path: Path | None = None,
    required: bool = False,
) -> None:
    path = path or STATUS_PATH
    payload = {
        "phase": phase,
        "requestID": request_id,
        "deviceUDID": device_udid,
        "simulationMayBeActive": simulation_may_be_active,
        "message": message,
        "updatedAt": time.time(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary_path.open("w", encoding="utf-8") as output:
            json.dump(payload, output, ensure_ascii=False, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
        if required:
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except OSError:
        logger.exception("Could not write worker status")
        with suppress(OSError):
            temporary_path.unlink()
        if required:
            raise


async def wait_or_stop(stop_event: asyncio.Event, timeout: float) -> None:
    with suppress(asyncio.TimeoutError):
        await asyncio.wait_for(stop_event.wait(), timeout=timeout)


async def wait_until_timeout_or_config_change(
    stop_event: asyncio.Event,
    timeout: float,
    starting_version: int,
) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while not stop_event.is_set():
        if config_version() != starting_version:
            return True
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            return False
        await wait_or_stop(stop_event, min(WAKE_CHECK_SECONDS, remaining))
    return False


async def resolve_target_device(saved_udid: str | None) -> tuple[str, bool]:
    if not saved_udid:
        saved_udid = load_config().get("targetUDID")
    process = await asyncio.create_subprocess_exec(
        "/usr/bin/xcrun", "devicectl", "list", "devices", "--quiet",
        "--timeout", "15", "--json-output", "-",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), 20)
    except BaseException:
        if process.returncode is None:
            process.kill()
        await process.wait()
        raise
    if process.returncode != 0:
        raise RuntimeError(stderr.decode(errors="replace"))
    data = json.loads(stdout[stdout.index(b"{"):])
    candidates = []
    for device in data["result"]["devices"]:
        properties = device.get("properties", {})
        hardware = properties.get("hardware", device.get("hardwareProperties", {}))
        connection = properties.get("connection", device.get("connectionProperties", {}))
        state = connection.get("state", connection.get("tunnelState"))
        if hardware.get("reality") == "physical" and hardware.get("deviceType") == "iPhone" and state in ("connected", "disconnected") and connection.get("transportType") in ("wired", "localNetwork"):
            candidates.append(hardware["udid"])
    if saved_udid:
        if saved_udid in candidates:
            return saved_udid, True
        raise NoDeviceConnectedError()
    if len(candidates) > 1:
        raise AmbiguousDeviceError("Several iPhones are connected; disconnect all but the intended target")
    if not candidates:
        raise NoDeviceConnectedError()
    return candidates[0], True


class CoreDeviceLocation:
    """Native Xcode backend using the Mac's existing trusted device tunnel."""

    def __init__(self, udid: str):
        self.udid = udid

    async def _run(self, operation: str, *arguments: str) -> None:
        process = await asyncio.create_subprocess_exec(
            "/usr/bin/xcrun", "devicectl", "device", "simulate", "location",
            operation, "--device", self.udid, "--timeout", "15", *arguments,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await process.communicate()
        except BaseException:
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
        if process.returncode != 0:
            raise RuntimeError((stderr or stdout).decode(errors="replace").strip())

    async def set(self, latitude: float, longitude: float) -> None:
        await self._run("coordinate", "--latitude", str(latitude), "--longitude", str(longitude))

    async def clear(self) -> None:
        await self._run("clear")


@asynccontextmanager
async def location_session(rsd):
    yield rsd

async def open_target_tunnel(target_udid: str, uses_remote_pairing: bool):
    return None, CoreDeviceLocation(target_udid)

async def close_tunnel(tunnel):
    pass

async def enable_wireless_connections(target_udid: str):
    pass


async def set_location_with_retry(
    location: CoreDeviceLocation,
    config: dict,
    stop_event: asyncio.Event,
) -> None:
    try:
        await asyncio.wait_for(
            location.set(config["latitude"], config["longitude"]),
            timeout=SET_TIMEOUT_SECONDS,
        )
    except Exception:
        if stop_event.is_set():
            raise
        logger.warning("Location refresh failed once; retrying")
        await wait_or_stop(stop_event, 1.0)
        await asyncio.wait_for(
            location.set(config["latitude"], config["longitude"]),
            timeout=SET_TIMEOUT_SECONDS,
        )


async def apply_location(
    location: CoreDeviceLocation,
    config: dict,
    stop_event: asyncio.Event,
    target_udid: str,
) -> None:
    # Persist the recovery latch before asking CoreDevice to change location.
    write_status(
        "applying",
        config["requestID"],
        True,
        target_udid,
        f"Applying {config['cityName']}…",
        required=True,
    )
    await set_location_with_retry(location, config, stop_event)
    write_status(
        "active",
        config["requestID"],
        True,
        target_udid,
        f"{config['cityName']}, {config['country']}",
    )


async def clear_over_open_tunnel(
    location: CoreDeviceLocation,
    config: dict,
    target_udid: str,
) -> None:
    write_status(
        "clearing",
        config["requestID"],
        True,
        target_udid,
        "Sending clear to iPhone…",
    )
    await asyncio.wait_for(location.clear(), timeout=SET_TIMEOUT_SECONDS)
    logger.info("Clear command sent successfully to %s", target_udid)
    write_status(
        "cleared",
        config["requestID"],
        False,
        target_udid,
        "The clear command was sent successfully",
        required=True,
    )


async def clear_location_for_config(config: dict, saved_udid: str | None) -> str:
    target_udid, uses_remote_pairing = await resolve_target_device(saved_udid)
    if not uses_remote_pairing:
        await enable_wireless_connections(target_udid)
    tunnel = None
    try:
        tunnel, rsd = await open_target_tunnel(target_udid, uses_remote_pairing)
        if rsd.udid != target_udid:
            raise RuntimeError(
                f"Connected to unexpected iPhone {rsd.udid}; expected {target_udid}"
            )
        async with location_session(rsd) as location:
            await clear_over_open_tunnel(location, config, target_udid)
        return target_udid
    finally:
        if tunnel is not None:
            await close_tunnel(tunnel)


async def run_worker(stop_event: asyncio.Event) -> None:
    previous_status = read_status()
    simulation_may_be_active = bool(previous_status.get("simulationMayBeActive", False))
    target_udid = previous_status.get("deviceUDID") if simulation_may_be_active else None
    last_logged_request_id = ""
    waiting_log_time = 0.0
    expired_heartbeat_request = ""
    cleanup_lease = None

    while not stop_event.is_set():
        version = config_version()
        try:
            config = load_config()
        except ConfigurationError as error:
            logger.error("Invalid configuration: %s", error)
            # Coordinates are unnecessary for clear. If config.json is damaged
            # or deleted, use the last durable request/device identity and keep
            # retrying a conservative restore instead of abandoning the phone.
            recovery_config = {
                "requestID": previous_status.get("requestID") or "configuration-recovery"
            }
            simulation_may_be_active = True
            write_status(
                "clearPending",
                recovery_config["requestID"],
                True,
                target_udid,
                f"Configuration is invalid; recovery clear is waiting for iPhone: {error}",
                required=True,
            )
            try:
                target_udid = await clear_location_for_config(recovery_config, target_udid)
                return
            except (DeviceNotFoundError, NoDeviceConnectedError):
                logger.warning("Recovery clear is waiting for the trusted iPhone")
            except Exception as clear_error:
                logger.exception("Recovery clear failed; retrying")
                write_status(
                    "clearPending",
                    recovery_config["requestID"],
                    True,
                    target_udid,
                    f"Recovery clear could not be sent: {clear_error}",
                )
            await wait_until_timeout_or_config_change(stop_event, 5, version)
            continue

        should_simulate, cleanup_lease = simulation_request_decision(
            config,
            cleanup_lease,
        )
        if config["simulationEnabled"] and not should_simulate:
            if expired_heartbeat_request != config["requestID"]:
                logger.warning("App heartbeat expired; forcing real GPS restoration")
                expired_heartbeat_request = config["requestID"]

        if (
            not should_simulate
            and previous_status.get("requestID") == config["requestID"]
            and previous_status.get("phase") == "cleared"
            and not previous_status.get("simulationMayBeActive", True)
        ):
            logger.info("Matching successful clear is already recorded; worker has nothing to do")
            return

        if not should_simulate and not previous_status:
            # Upgrading from an older build: there may be a device-side simulation
            # even though no machine-readable status exists yet.
            simulation_may_be_active = True

        phase = "connecting" if should_simulate else "clearPending"
        message = (
            "Connecting to iPhone…"
            if should_simulate
            else "Restore GPS is waiting for a trusted iPhone connection"
        )
        write_status(
            phase,
            config["requestID"],
            simulation_may_be_active,
            target_udid,
            message,
        )

        try:
            target_udid, uses_remote_pairing = await resolve_target_device(target_udid)
            if not uses_remote_pairing:
                await enable_wireless_connections(target_udid)

            tunnel = None
            try:
                tunnel, rsd = await open_target_tunnel(target_udid, uses_remote_pairing)
                actual_udid = rsd.udid
                if actual_udid != target_udid:
                    raise RuntimeError(
                        f"Connected to unexpected iPhone {actual_udid}; expected {target_udid}"
                    )

                async with location_session(rsd) as location:
                    logger.info("Connected to iPhone %s", target_udid)
                    refresh_count = 0

                    while not stop_event.is_set():
                        config = load_config()
                        version = config_version()
                        should_simulate, cleanup_lease = simulation_request_decision(
                            config,
                            cleanup_lease,
                        )

                        if not should_simulate:
                            try:
                                await clear_over_open_tunnel(location, config, target_udid)
                            except Exception as error:
                                simulation_may_be_active = True
                                write_status(
                                    "clearPending",
                                    config["requestID"],
                                    True,
                                    target_udid,
                                    f"Clear could not be sent: {error}",
                                )
                                raise
                            return

                        simulation_may_be_active = True
                        try:
                            await apply_location(location, config, stop_event, target_udid)
                        except Exception:
                            logger.exception("Location refresh failed; reconnecting cleanly")
                            with suppress(Exception):
                                await clear_over_open_tunnel(location, config, target_udid)
                                simulation_may_be_active = False
                            raise

                        refresh_count += 1
                        if config["requestID"] != last_logged_request_id or refresh_count % 20 == 0:
                            logger.info(
                                "Location set: %s, %s (%.4f, %.4f) on %s",
                                config["cityName"],
                                config["country"],
                                config["latitude"],
                                config["longitude"],
                                target_udid,
                            )
                            last_logged_request_id = config["requestID"]

                        await wait_until_timeout_or_config_change(
                            stop_event,
                            config["refreshSeconds"],
                            version,
                        )

                    if simulation_may_be_active:
                        try:
                            await clear_over_open_tunnel(location, config, target_udid)
                            simulation_may_be_active = False
                        except Exception as error:
                            write_status(
                                "clearPending",
                                config["requestID"],
                                True,
                                target_udid,
                                f"Worker shutdown could not send clear: {error}",
                                required=True,
                            )
                            raise
            finally:
                if tunnel is not None:
                    await close_tunnel(tunnel)

        except (DeviceNotFoundError, NoDeviceConnectedError):
            now = time.monotonic()
            if now - waiting_log_time >= 60:
                logger.warning("Target iPhone is not connected; waiting")
                waiting_log_time = now
            should_simulate, cleanup_lease = simulation_request_decision(
                config,
                cleanup_lease,
            )
            phase = "waitingForDevice" if should_simulate else "clearPending"
            message = (
                "Connect the unlocked iPhone over USB"
                if should_simulate
                else "Restore GPS is waiting for trusted USB or Wi-Fi"
            )
            write_status(
                phase,
                config["requestID"],
                simulation_may_be_active,
                target_udid,
                message,
            )
        except AmbiguousDeviceError as error:
            logger.error("%s", error)
            write_status(
                "failed",
                config["requestID"],
                simulation_may_be_active,
                target_udid,
                "Several iPhones are connected; leave only the intended target",
            )
        except asyncio.CancelledError:
            raise
        except Exception as error:
            logger.exception("Connection failed; retrying")
            should_simulate, cleanup_lease = simulation_request_decision(
                config,
                cleanup_lease,
            )
            phase = "failed" if should_simulate else "clearPending"
            write_status(
                phase,
                config["requestID"],
                simulation_may_be_active,
                target_udid,
                f"Connection error: {error}",
            )

        if stop_event.is_set():
            return
        await wait_until_timeout_or_config_change(
            stop_event,
            config["retrySeconds"],
            version,
        )


async def clear_location_once() -> None:
    config = load_config()
    status = read_status()
    await clear_location_for_config(config, status.get("deviceUDID"))


async def main() -> None:
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def request_stop() -> None:
        stop_event.set()
        loop.call_later(
            STOP_GRACE_SECONDS,
            lambda: os._exit(forced_shutdown_exit_code()),
        )

    loop.add_signal_handler(signal.SIGINT, request_stop)
    loop.add_signal_handler(signal.SIGTERM, request_stop)

    logger.info("Pinshift worker started")
    try:
        await run_worker(stop_event)
        if stop_event.is_set() and forced_shutdown_exit_code() != 0:
            raise RuntimeError("Worker stopped before a durable successful clear status")
    finally:
        logger.info("Pinshift worker stopped")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pinshift location simulation worker")
    parser.add_argument("--clear", action="store_true", help="Clear the simulated location once and exit")
    arguments = parser.parse_args()
    try:
        asyncio.run(clear_location_once() if arguments.clear else main())
    except Exception:
        logger.exception("Pinshift worker failed")
        raise SystemExit(1)
