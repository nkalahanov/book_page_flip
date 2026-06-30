// Internal engine for the book_page_flip package: the 3D page mesh, perspective
// projection, render scene, painter, and the BookFlip widget. This is the
// library's umbrella file — the implementation lives in the `part` files below
// (tunables, geometry, scene, api, state, rendering), which share its imports and
// library privacy. Package-private by convention: consumers import
// 'package:book_page_flip/book_page_flip.dart', never this file. Inline comments are
// maintainer notes, not API docs.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

part 'tunables.dart';
part 'geometry.dart';
part 'scene.dart';
part 'api.dart';
part 'state.dart';
part 'rendering.dart';
part 'widget_capture.dart';
part 'widget_pages.dart';
