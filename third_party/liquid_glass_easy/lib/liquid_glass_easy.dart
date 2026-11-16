export 'package:liquid_glass_easy/src/widgets/liquid_glass_view.dart';
export 'package:liquid_glass_easy/src/widgets/liquid_glass_style.dart'
    show LiquidGlassStyle;

// ── Lens-anywhere & batching API ───────────────────────────
export 'package:liquid_glass_easy/src/widgets/lens/liquid_glass_lens.dart'
    show LiquidGlassLens;
export 'package:liquid_glass_easy/src/widgets/lens/liquid_glass_batch.dart'
    show LiquidGlassBatch;
export 'package:liquid_glass_easy/src/widgets/lens/liquid_glass_blender.dart'
    show LiquidGlassBlender;
export 'package:liquid_glass_easy/src/widgets/lens/liquid_glass_shaders.dart'
    show LiquidGlassShaders;
export 'package:liquid_glass_easy/src/widgets/liquid_glass_engine.dart'
    show LiquidGlassEngine;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_lite.dart'
    show LiquidGlassLite;

export 'package:liquid_glass_easy/src/controllers/liquid_glass_controller.dart';
export 'package:liquid_glass_easy/src/controllers/liquid_glass_view_controller.dart';

// ── Adaptivity, scroll-edge & geometry helpers ─────────────
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_adaptivity.dart'
    show
        LiquidGlassAdaptivity,
        LiquidGlassAdaptiveSampling,
        LiquidGlassAdaptivityLink,
        LiquidGlassAdaptivityController,
        LiquidGlassBrightnessFallback,
        LiquidGlassSystemChrome;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_adaptive_area.dart'
    show LiquidGlassAdaptiveArea, LiquidGlassAdaptiveAreaScope;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_scroll_edge.dart'
    show LiquidGlassScrollEdge, LiquidGlassEdge, LiquidGlassScrollEdgeStyle;
export 'package:liquid_glass_easy/src/widgets/components/scroll_edge_input_group.dart'
    show LiquidGlassScrollEdgeGroup;
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_shape.dart'
    hide
        liquidGlassOutlinePath,
        liquidGlassUsesExactClipPath,
        LiquidGlassLitShape;
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_light.dart';
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_refresh_rate.dart';
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_position.dart';
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_spring.dart';
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_touch.dart';
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_flex.dart'
    show
        LiquidGlassFlex,
        LiquidGlassFlexDeform,
        LiquidGlassFlexAdvanced,
        LiquidGlassFlexOutline,
        debugLiquidGlassFlexOutline;

// ── Active form controls & motion primitives ───────────────
export 'package:liquid_glass_easy/src/widgets/components/slider/liquid_glass_slider.dart'
    show LiquidGlassSlider, LiquidGlassSliderLayout;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_motion_pill.dart'
    show LiquidGlassMotionPill;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_shadow.dart'
    show LiquidGlassShadow;
export 'package:liquid_glass_easy/src/widgets/utils/liquid_glass_lens_motion.dart'
    show LiquidGlassLensMotion, LiquidGlassLensMotionSpec;
export 'package:liquid_glass_easy/src/widgets/components/switch/liquid_glass_switch.dart'
    show LiquidGlassSwitch, LiquidGlassSwitchLayout;
export 'package:liquid_glass_easy/src/widgets/components/liquid_glass_segmented.dart'
    show
        LiquidGlassSegmented,
        LiquidGlassSegmentedPillStyle,
        LiquidGlassSegmentedLabelStyle;
