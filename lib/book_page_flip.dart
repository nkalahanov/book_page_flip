/// A smooth, efficient open-book page-flip widget.
///
/// Supply decoded page images to [BookFlip], or any widgets via [BookFlip.builder],
/// and the user can turn pages with a drag — or drive it from code with a
/// [BookFlipController]. Tune the feel with [BookFlipPhysics], the paper with
/// [BookFlipMaterial], the page-curve with [BookFlipCurl], which effects draw with
/// [BookFlipEffects], and how it fits its space with [BookFit].
library;

export 'src/engine.dart'
    show
        BookFit,
        BookFlip,
        BookFlipController,
        BookFlipCurl,
        BookFlipEffects,
        BookFlipMaterial,
        BookFlipPhysics,
        FlipDirection;
