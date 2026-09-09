import asyncio
import fcntl
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


KEEPER_PATH = Path(__file__).parents[2] / "App/Resources/keeper.py"
os.environ["PINSHIFT_LOG_PATH"] = f"/tmp/pinshift-worker-tests-{os.getpid()}.log"
SPEC = importlib.util.spec_from_file_location("pinshift_keeper", KEEPER_PATH)
keeper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(keeper)


class ConfigurationTests(unittest.TestCase):
    def test_missing_config_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(keeper.ConfigurationError):
                keeper.load_config(Path(directory) / "missing.json")

    def test_invalid_coordinates_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps({
                "cityID": "bad",
                "cityName": "Bad",
                "country": "Bad",
                "latitude": 200,
                "longitude": 20,
                "retrySeconds": 5,
                "refreshSeconds": 10,
                "requestID": "request",
            }))

            with self.assertRaises(keeper.ConfigurationError):
                keeper.load_config(path)

    def test_stale_app_heartbeat_turns_simulation_into_restore(self):
        config = {
            "simulationEnabled": True,
            "appHeartbeatAt": 1_000.0,
        }

        cleanup_lease = object()
        should_simulate, returned_lease = keeper.simulation_request_decision(
            config,
            cleanup_lease=cleanup_lease,
            now=1_301.0,
        )
        self.assertFalse(should_simulate)
        self.assertIs(returned_lease, cleanup_lease)

    def test_stale_app_heartbeat_keeps_simulation_when_gui_is_alive(self):
        config = {
            "simulationEnabled": True,
            "appHeartbeatAt": 1_000.0,
        }

        with patch.object(
            keeper,
            "acquire_app_cleanup_lease",
            return_value=("alive", None),
        ):
            should_simulate, cleanup_lease = keeper.simulation_request_decision(
                config,
                now=1_301.0,
            )
        self.assertTrue(should_simulate)
        self.assertIsNone(cleanup_lease)

    def test_liveness_probe_error_never_proves_gui_death(self):
        config = {
            "simulationEnabled": True,
            "appHeartbeatAt": 1_000.0,
        }

        with patch.object(
            keeper,
            "acquire_app_cleanup_lease",
            return_value=("unknown", None),
        ):
            should_simulate, cleanup_lease = keeper.simulation_request_decision(
                config,
                now=1_301.0,
            )
        self.assertTrue(should_simulate)
        self.assertIsNone(cleanup_lease)

    def test_fresh_app_heartbeat_keeps_simulation_requested(self):
        config = {
            "simulationEnabled": True,
            "appHeartbeatAt": 1_000.0,
        }

        should_simulate, cleanup_lease = keeper.simulation_request_decision(
            config,
            now=1_299.0,
        )
        self.assertTrue(should_simulate)
        self.assertIsNone(cleanup_lease)

    def test_missing_app_heartbeat_restores_after_gui_death(self):
        cleanup_lease = object()
        should_simulate, returned_lease = keeper.simulation_request_decision(
            {"simulationEnabled": True},
            cleanup_lease=cleanup_lease,
        )
        self.assertFalse(should_simulate)
        self.assertIs(returned_lease, cleanup_lease)

    def test_liveness_lock_distinguishes_live_and_dead_gui(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "gui-liveness.lock"
            descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                state, cleanup_lease = keeper.acquire_app_cleanup_lease(path)
                self.assertEqual(state, "alive")
                self.assertIsNone(cleanup_lease)
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

            state, cleanup_lease = keeper.acquire_app_cleanup_lease(path)
            self.assertEqual(state, "dead")
            self.assertIsNotNone(cleanup_lease)

            competing_descriptor = os.open(path, os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(
                        competing_descriptor,
                        fcntl.LOCK_EX | fcntl.LOCK_NB,
                    )
            finally:
                os.close(competing_descriptor)

            cleanup_lease.close()
            replacement_state, replacement_lease = keeper.acquire_app_cleanup_lease(path)
            self.assertEqual(replacement_state, "dead")
            replacement_lease.close()


class WorkerSafetyTests(unittest.IsolatedAsyncioTestCase):
    def test_forced_shutdown_is_successful_only_after_durable_clear(self):
        self.assertEqual(
            keeper.forced_shutdown_exit_code({
                "phase": "cleared",
                "simulationMayBeActive": False,
            }),
            0,
        )
        self.assertEqual(
            keeper.forced_shutdown_exit_code({
                "phase": "clearPending",
                "simulationMayBeActive": True,
            }),
            75,
        )

    async def test_latch_is_written_before_location_set(self):
        with tempfile.TemporaryDirectory() as directory:
            status_path = Path(directory) / "status.json"
            config = {
                "requestID": "request",
                "cityName": "Belgrade",
                "country": "Serbia",
                "latitude": 44.8125,
                "longitude": 20.4612,
            }

            class FakeLocation:
                async def set(self, latitude, longitude):
                    status = keeper.read_status(status_path)
                    self.assertEqual(status["phase"], "applying")
                    self.assertTrue(status["simulationMayBeActive"])

            location = FakeLocation()
            location.assertEqual = self.assertEqual
            location.assertTrue = self.assertTrue

            with patch.object(keeper, "STATUS_PATH", status_path):
                await keeper.apply_location(
                    location,
                    config,
                    asyncio.Event(),
                    "target-phone",
                )

            status = keeper.read_status(status_path)
            self.assertEqual(status["phase"], "active")
            self.assertEqual(status["deviceUDID"], "target-phone")

    async def test_failed_latch_write_prevents_location_set(self):
        location = SimpleNamespace(set_called=False)

        async def fake_set(latitude, longitude):
            location.set_called = True

        location.set = fake_set
        config = {
            "requestID": "request",
            "cityName": "Belgrade",
            "country": "Serbia",
            "latitude": 44.8125,
            "longitude": 20.4612,
        }

        with patch.object(keeper, "write_status", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                await keeper.apply_location(
                    location,
                    config,
                    asyncio.Event(),
                    "target-phone",
                )

        self.assertFalse(location.set_called)

    async def test_failed_clear_never_writes_cleared_status(self):
        with tempfile.TemporaryDirectory() as directory:
            status_path = Path(directory) / "status.json"
            config = {"requestID": "request"}

            class FakeLocation:
                async def clear(self):
                    raise TimeoutError("device stopped responding")

            with patch.object(keeper, "STATUS_PATH", status_path):
                with self.assertRaises(TimeoutError):
                    await keeper.clear_over_open_tunnel(
                        FakeLocation(),
                        config,
                        "target-phone",
                    )

            status = keeper.read_status(status_path)
            self.assertEqual(status["phase"], "clearing")
            self.assertTrue(status["simulationMayBeActive"])

    async def test_successful_clear_writes_false_latch(self):
        with tempfile.TemporaryDirectory() as directory:
            status_path = Path(directory) / "status.json"
            config = {"requestID": "request"}

            class FakeLocation:
                async def clear(self):
                    return None

            with patch.object(keeper, "STATUS_PATH", status_path):
                await keeper.clear_over_open_tunnel(
                    FakeLocation(),
                    config,
                    "target-phone",
                )

            status = keeper.read_status(status_path)
            self.assertEqual(status["phase"], "cleared")
            self.assertFalse(status["simulationMayBeActive"])

    async def test_disabled_worker_keeps_clear_pending_without_device(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            status_path = Path(directory) / "status.json"
            config_path.write_text(json.dumps({
                "cityID": "moscow",
                "cityName": "Moscow",
                "country": "Russia",
                "latitude": 55.7558,
                "longitude": 37.6173,
                "retrySeconds": 5,
                "refreshSeconds": 10,
                "requestID": "restore-request",
                "simulationEnabled": False,
            }))
            stop_event = asyncio.Event()

            async def no_devices(*args):
                raise keeper.NoDeviceConnectedError()

            async def stop_after_first_attempt(*args, **kwargs):
                stop_event.set()
                return False

            with (
                patch.object(keeper, "CONFIG_PATH", config_path),
                patch.object(keeper, "STATUS_PATH", status_path),
                patch.object(keeper, "resolve_target_device", no_devices),
                patch.object(
                    keeper,
                    "wait_until_timeout_or_config_change",
                    stop_after_first_attempt,
                ),
            ):
                await keeper.run_worker(stop_event)

            status = keeper.read_status(status_path)
            self.assertEqual(status["phase"], "clearPending")
            self.assertTrue(status["simulationMayBeActive"])

    async def test_invalid_config_attempts_conservative_clear(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            status_path = Path(directory) / "status.json"
            config_path.write_text("not-json")
            status_path.write_text(json.dumps({
                "phase": "active",
                "requestID": "last-known-request",
                "deviceUDID": "target-phone",
                "simulationMayBeActive": True,
            }))
            stop_event = asyncio.Event()

            async def no_device(*args, **kwargs):
                raise keeper.NoDeviceConnectedError()

            async def stop_after_first_attempt(*args, **kwargs):
                stop_event.set()
                return False

            with (
                patch.object(keeper, "CONFIG_PATH", config_path),
                patch.object(keeper, "STATUS_PATH", status_path),
                patch.object(keeper, "clear_location_for_config", no_device),
                patch.object(
                    keeper,
                    "wait_until_timeout_or_config_change",
                    stop_after_first_attempt,
                ),
            ):
                await keeper.run_worker(stop_event)

            status = keeper.read_status(status_path)
            self.assertEqual(status["phase"], "clearPending")
            self.assertEqual(status["requestID"], "last-known-request")
            self.assertTrue(status["simulationMayBeActive"])

    async def test_matching_cleared_status_exits_without_reopening_phone(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            status_path = Path(directory) / "status.json"
            config_path.write_text(json.dumps({
                "cityID": "moscow",
                "cityName": "Moscow",
                "country": "Russia",
                "latitude": 55.7558,
                "longitude": 37.6173,
                "retrySeconds": 5,
                "refreshSeconds": 10,
                "requestID": "cleared-request",
                "simulationEnabled": False,
            }))
            status_path.write_text(json.dumps({
                "phase": "cleared",
                "requestID": "cleared-request",
                "deviceUDID": "target-phone",
                "simulationMayBeActive": False,
                "message": "cleared",
                "updatedAt": 1,
            }))

            async def must_not_resolve(*args, **kwargs):
                self.fail("A recorded successful clear must not reopen a device connection")

            with (
                patch.object(keeper, "CONFIG_PATH", config_path),
                patch.object(keeper, "STATUS_PATH", status_path),
                patch.object(keeper, "resolve_target_device", must_not_resolve),
            ):
                await keeper.run_worker(asyncio.Event())


class NativeDiscoveryTests(unittest.IsolatedAsyncioTestCase):
    async def discover(self, devices, saved=None):
        class Process:
            returncode = 0
            async def communicate(self):
                return json.dumps({"result": {"devices": devices}}).encode(), b""
        async def launch(*args, **kwargs):
            return Process()
        with patch.object(keeper.asyncio, "create_subprocess_exec", launch), patch.object(keeper, "load_config", return_value={}):
            return await keeper.resolve_target_device(saved)

    def phone(self, udid, state="connected", transport="localNetwork", reality="physical"):
        return {"properties": {"hardware": {"udid": udid, "deviceType": "iPhone", "reality": reality}, "connection": {"state": state, "transportType": transport}}}

    async def test_multiple_phones_require_explicit_target(self):
        with self.assertRaises(keeper.AmbiguousDeviceError):
            await self.discover([self.phone("a"), self.phone("b")])
        self.assertEqual(await self.discover([self.phone("a"), self.phone("b")], "b"), ("b", True))

    async def test_sleeping_wifi_tunnel_is_reachable_but_simulator_is_excluded(self):
        result = await self.discover([self.phone("phone", state="disconnected"), self.phone("sim", transport="sameMachine", reality="simulated")])
        self.assertEqual(result, ("phone", True))

    async def test_missing_saved_phone_never_falls_back_to_another_phone(self):
        with self.assertRaises(keeper.NoDeviceConnectedError):
            await self.discover([self.phone("other")], "target")

    async def test_native_location_error_is_not_acknowledged_as_success(self):
        class Process:
            returncode = 1
            async def communicate(self):
                return b"", b"Device is locked"
        async def launch(*args, **kwargs):
            return Process()
        with patch.object(keeper.asyncio, "create_subprocess_exec", launch):
            with self.assertRaisesRegex(RuntimeError, "Device is locked"):
                await keeper.CoreDeviceLocation("target").set(50, 14)


if __name__ == "__main__":
    unittest.main()
