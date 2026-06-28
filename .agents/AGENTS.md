# Malphas Identity & Design Guidelines

These rules define the design language, aesthetic guidelines, and behavioral constraints of the Malphas project. All agents modifying the user interface or system mechanics must follow these rules.

## 1. Terminal Aesthetic
Malphas functions and behaves like an immersive graphical terminal. It rejects standard mobile app layouts, messaging bubbles, web navigation, or social media designs.

## 2. Radical Dark Palette
- **Base Color:** Black Absolute (`#000000`) to disable pixels on OLED screens.
- **Secondary Containers:** Matte Anthracite / Ultra Dark Grey (`#0D0D0D` / `#161616`).
- **Typography Tone:** High-contrast Bone/Ivory (`#E0DCD3`) to prevent eye fatigue.
- **Borders:** Thin, subtle separators (`#1B1B1B`).

## 3. Strict Typography
- **Titles & Structural Headers:** Classic serif fonts (e.g., Georgia) to evoke solemnity and high-quality premium craft.
- **Data, Stats & Telemetry:** Clean, strictly geometric sans-serif or monospaced fonts (e.g., Courier/Roboto) to present pure data.

## 4. Organic Geometry
- All docks, text inputs, and action overlays must float on top of the passive canvas rather than stick to the screen edges.
- Borders must use extreme rounded corners (e.g., radius of 24-30px) to form capsules for controls.

## 5. Architectural Integrity
- Keep the rendering pipeline repaint-driven. Do not trigger global Flutter build/re-layouts on high-speed ticks.
- Maintain the virtual coordinates matrix of `1000x1000` logical units and apply letterboxing to preserve aspect ratios on dynamic screens.
