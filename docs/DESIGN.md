# Pinshift design

The Mac is a menu bar accessory with a small native pairing popover and no Dock icon or main window. The iPhone uses a full-screen MapKit map with its standard marker and a draggable SwiftUI sheet. Start/Stop stays at the bottom while pulling up the native list reveals favorites. Search and Connection use the same navigation stack at medium sheet height. System colors, fonts, controls, and accessibility sizing replace custom cards and overlays. All application strings are English; map labels and proper place names come from MapKit.

Search results use primary text for place names and coordinates, secondary text for concise addresses, and neutral SF Symbols. Repeated address components and duplicate results are removed. MapKit searches use the selected map area as a relevance hint while still accepting worldwide place names and coordinates.

The generated logo source is [App/Resources/Logo.png](../App/Resources/Logo.png). The Xcode asset catalog contains the Mac and iPhone icons derived from it.

## Image generation prompt

Use case: logo-brand. Create a single app-icon inner symbol asset for Pinshift, an elegant Apple-native location-control app. A bold three-dimensional map pin made of glossy translucent white glass, with a small luminous mint/turquoise inner navigation arrow integrated into its circular opening. One distinctive continuous sculptural pin silhouette, softly rounded edges, subtle white glow, straight-on view, extremely readable at small sizes. Premium restrained Apple-style icon object. Pure solid black (#000000) background, centered square 1024 by 1024 composition, icon fills about 72 percent of the square with ample equal padding. No text, letters, numbers, grid, outlines around the canvas, external rounded-square icon frame, checkerboard, maps, extra objects or watermark. Smooth carefully polished surfaces; strong recognizable silhouette. Save as PNG.
