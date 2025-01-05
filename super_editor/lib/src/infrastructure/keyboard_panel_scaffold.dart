import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/src/default_editor/document_ime/document_input_ime.dart';
import 'package:super_editor/src/infrastructure/_logging.dart';
import 'package:super_editor/src/infrastructure/flutter/flutter_scheduler.dart';
import 'package:super_keyboard/super_keyboard.dart';

/// Scaffold that displays the given [contentBuilder], while also (optionally) displaying
/// a toolbar docked to the top of the software keyboard, and/or a panel that appears
/// instead of the software keyboard.
///
/// A typical use case for the keyboard panel is a chat application switching between the
/// software keyboard and an emoji panel.
///
/// To correctly use this scaffold, you must place a [KeyboardScaffoldSafeArea] higher in
/// the widget tree to adjust the padding so that the content is above the keyboard panel
/// and software keyboard. The [KeyboardScaffoldSafeArea] can go anywhere higher in the tree,
/// so long as the [KeyboardScaffoldSafeArea] takes up the entire screen.
///
/// The widget returned by [toolbarBuilder] is positioned above the keyboard panel, when
/// visible, or above the software keyboard, when visible. If neither the keyboard panel nor
/// the software keyboard are visible, the widget is positioned at the bottom of the screen.
///
/// The widget returned by [keyboardPanelBuilder] is positioned at the bottom of the screen,
/// with its height constrained to be equal to the software keyboard height.
///
/// The widget returned by [contentBuilder] is positioned above the above-keyboard panel,
/// using all the remaining height.
///
/// Use the [controller] to show/hide the keyboard panel and software keyboard.
///
/// If there is a [Scaffold] in your widget tree, it must have `resizeToAvoidBottomInset`
/// set to `false`, otherwise we can't get the software keyboard height to size the keyboard
/// panel. If `resizeToAvoidBottomInset` is set to `true`, the panel won't be displayed.
class KeyboardPanelScaffold<PanelType> extends StatefulWidget {
  const KeyboardPanelScaffold({
    super.key,
    required this.controller,
    required this.isImeConnected,
    required this.toolbarBuilder,
    required this.keyboardPanelBuilder,
    this.fallbackPanelHeight = 250,
    required this.contentBuilder,
  });

  /// Controls the visibility of the keyboard toolbar, keyboard panel, and software keyboard.
  final KeyboardPanelController<PanelType> controller;

  /// A [ValueListenable] that should notify this [KeyboardPanelScaffold] when the IME connects
  /// and disconnects.
  ///
  /// This signal is used to automatically close any open panel when the IME disconnects.
  final ValueListenable<bool> isImeConnected;

  /// Builds the toolbar that's docked to the top of the software keyboard area.
  final Widget Function(BuildContext context, PanelType? openPanel) toolbarBuilder;

  /// Builds the keyboard panel that's displayed in place of the software keyboard.
  final Widget Function(BuildContext context, PanelType? openPanel) keyboardPanelBuilder;

  /// The height of the keyboard panel in situations where no software keyboard is
  /// present, e.g., on a tablet when using a physical keyboard, or when using a floating
  /// software keyboard.
  final double fallbackPanelHeight;

  /// Builds the regular widget subtree beneath this widget.
  ///
  /// This is the content that this widget "wraps". Sometimes this content might be
  /// a whole screen of content, or other times this content might be a single widget
  /// like a text field or an editor.
  final Widget Function(BuildContext context, PanelType? openPanel) contentBuilder;

  @override
  State<KeyboardPanelScaffold<PanelType>> createState() => _KeyboardPanelScaffoldState<PanelType>();
}

class _KeyboardPanelScaffoldState<PanelType> extends State<KeyboardPanelScaffold<PanelType>>
    with SingleTickerProviderStateMixin
    implements KeyboardPanelScaffoldDelegate<PanelType> {
  /// Whether we've run at least one didChangeDependencies, which is initially
  /// used to check for existing bottom insets.
  bool _didInitializeViewInsets = false;

  /// The best guess of the height of the fully open software keyboard.
  ///
  /// The OS doesn't report this info. We observe the bottom insets and retain
  /// the tallest value that we see.
  ///
  /// Note: There may be situations in which an "open" keyboard corresponds to
  /// multiple possible heights. For example, on an iPad, iOS reports an "open"
  /// keyboard when the software keyboard is up, as well as when the small "minimized"
  /// keyboard toolbar is visible. The minimized version is only 69 pixels tall.
  double _bestGuessMaxKeyboardHeight = 0.0;

  /// The current visual state of the keyboard, e.g., closed, opening, open, closing.
  KeyboardState _keyboardState = KeyboardState.closed;

  /// The height of the software keyboard at this moment.
  double _currentKeyboardHeight = 0.0;

  /// The height of the visible panel at this moment.
  late final AnimationController _panelHeightController;
  late Animation<double> _panelHeight;

  /// The currently visible panel.
  PanelType? _activePanel;

  /// The current bottom spacing, which might be equal to a panel height, or the
  /// current keyboard height, or it might be an intermediate spacing as we switch
  /// between a panel and keyboard.
  final _currentBottomSpacing = ValueNotifier<double>(0.0);

  /// Shows/hides the [OverlayPortal] containing the keyboard panel and above-keyboard panel.
  final OverlayPortalController _overlayPortalController = OverlayPortalController();

  bool get _wantsToShowToolbar =>
      widget.controller.toolbarVisibility == KeyboardToolbarVisibility.visible ||
      (widget.controller.toolbarVisibility == KeyboardToolbarVisibility.auto &&
          (widget.isImeConnected.value || wantsToShowKeyboardPanel));

  final _toolbarKey = GlobalKey();

  SoftwareKeyboardController? _softwareKeyboardController;

  KeyboardScaffoldSafeAreaMutator? _ancestorSafeArea;

  @override
  void initState() {
    super.initState();
    assert(() {
      final scaffold = Scaffold.maybeOf(context);
      if (scaffold != null && scaffold.widget.resizeToAvoidBottomInset != false) {
        throw FlutterError(
          'KeyboardPanelScaffold is placed inside a Scaffold with resizeToAvoidBottomInset set to true.\n'
          'This will produce incorrect results. Set resizeToAvoidBottomInset to false.',
        );
      }
      return true;
    }());

    _panelHeightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    )..addListener(_onPanelHeightChange);
    _updateMaxPanelHeight();

    widget.controller.attach(this);

    widget.isImeConnected.addListener(_onImeConnectionChange);

    SuperKeyboard.instance.state.addListener(_onKeyboardStateChange);

    _overlayPortalController.show();
    onNextFrame((_) {
      // Do initial safe area report to our ancestor keyboard safe area widget,
      // after we've added our UI to the overlay portal.
      _updateSafeArea();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _ancestorSafeArea = KeyboardScaffoldSafeArea.maybeOf(context);
    if (!_didInitializeViewInsets) {
      _didInitializeViewInsets = true;
      _bestGuessMaxKeyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
      _updateMaxPanelHeight();
    }

    _updateKeyboardHeightForCurrentViewInsets();
  }

  @override
  void didUpdateWidget(KeyboardPanelScaffold<PanelType> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.detach();
      widget.controller.attach(this);
    }

    if (widget.isImeConnected != oldWidget.isImeConnected) {
      oldWidget.isImeConnected.removeListener(_onImeConnectionChange);
      widget.isImeConnected.addListener(_onImeConnectionChange);
    }

    if (widget.fallbackPanelHeight != oldWidget.fallbackPanelHeight) {
      _updateMaxPanelHeight();
    }
  }

  @override
  void reassemble() {
    super.reassemble();

    // In case we made a code change during development that impacts the
    // visibility of the toolbar. Re-calculate the ancestor keyboard safe area.
    _updateSafeArea();
  }

  @override
  void dispose() {
    _ancestorSafeArea?.geometry = const KeyboardSafeAreaGeometry();

    SuperKeyboard.instance.state.removeListener(_onKeyboardStateChange);

    widget.isImeConnected.removeListener(_onImeConnectionChange);

    widget.controller.detach();

    // _panelAnimation.removeListener(_updatePanelForExitAnimation);
    _panelHeightController.removeListener(_onPanelHeightChange);
    _panelHeightController.dispose();

    if (_overlayPortalController.isShowing) {
      // WARNING: We can only call `hide()` if `isShowing` is `true`. If we blindly
      // call `hide()` then we'll get a z-index error reported. Flutter should clean
      // that up internally, but until then (written Oct 14, 2024) we guard it here.
      _overlayPortalController.hide();
    }

    _listeners.clear();

    super.dispose();
  }

  void _onKeyboardStateChange() {
    _keyboardState = SuperKeyboard.instance.state.value;

    // Note: The following post frame callback shouldn't be necessary.
    // We should be able to look up our ancestor MediaQuery immediately.
    // However, it was found when writing tests that at the end of a test
    // the order in which Flutter disposes of widgets was resulting in an
    // attempt to access a disposed MediaQuery. I think this is probably a
    // bug in Flutter somewhere. To work around it, we do the update at the
    // end of the current frame, and we check that we're still mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      _updateKeyboardHeightForCurrentViewInsets();
    });
  }

  void _updateMaxPanelHeight() {
    _panelHeight = Tween(
      begin: 0.0,
      end: _bestGuessMaxKeyboardHeight > 100 ? _bestGuessMaxKeyboardHeight : widget.fallbackPanelHeight,
    ) //
        .chain(CurveTween(curve: Curves.easeInOut))
        .animate(_panelHeightController);
  }

  void _onPanelHeightChange() {
    _updateSafeArea();
    _currentBottomSpacing.value = max(_panelHeight.value, _currentKeyboardHeight);
  }

  @override
  void onAttached(SoftwareKeyboardController softwareKeyboardController) {
    _softwareKeyboardController = softwareKeyboardController;
  }

  @override
  void onDetached() {
    _softwareKeyboardController = null;
  }

  void _onImeConnectionChange() {
    final isImeConnected = widget.isImeConnected.value;
    if (isImeConnected) {
      setState(() {
        // Rebuild because we may need to show the toolbar now that the IME
        // is connected.
      });

      return;
    }

    // The IME isn't connected. Ensure the panel is closed.
    widget.controller.closeKeyboardAndPanel();
  }

  /// Whether the toolbar should be displayed, anchored to the top of the keyboard area.
  @override
  KeyboardToolbarVisibility get toolbarVisibility => _toolbarVisibility;
  KeyboardToolbarVisibility _toolbarVisibility = KeyboardToolbarVisibility.auto;
  @override
  set toolbarVisibility(KeyboardToolbarVisibility value) {
    if (value == _toolbarVisibility) {
      return;
    }

    _toolbarVisibility = value;
    switch (value) {
      case KeyboardToolbarVisibility.visible:
        showToolbar();
      case KeyboardToolbarVisibility.hidden:
        hideToolbar();
      case KeyboardToolbarVisibility.auto:
        _wantsToShowSoftwareKeyboard || _wantsToShowKeyboardPanel //
            ? showToolbar()
            : hideToolbar();
    }
  }

  bool _isToolbarVisible = false;

  /// Shows the toolbar, if it's hidden, or hides the toolbar, if it's visible.
  @override
  void toggleToolbar() {
    if (_isToolbarVisible) {
      hideToolbar();
    } else {
      showToolbar();
    }
  }

  /// Shows the toolbar that's mounted to the top of the keyboard area.
  @override
  void showToolbar() {
    setState(() {
      _toolbarVisibility = KeyboardToolbarVisibility.visible;
      _isToolbarVisible = true;
    });
  }

  /// Hides the toolbar that's mounted to the top of the keyboard area.
  @override
  void hideToolbar() {
    setState(() {
      _toolbarVisibility = KeyboardToolbarVisibility.hidden;
      _isToolbarVisible = false;
    });
  }

  /// Whether the software keyboard should be displayed, instead of the keyboard panel.
  bool get wantsToShowSoftwareKeyboard => _wantsToShowSoftwareKeyboard;
  bool _wantsToShowSoftwareKeyboard = false;

  @override
  bool get isSoftwareKeyboardOpen => _wantsToShowSoftwareKeyboard;

  /// Shows the software keyboard, if it's hidden.
  @override
  void showSoftwareKeyboard() {
    setState(() {
      _wantsToShowKeyboardPanel = false;
      _wantsToShowSoftwareKeyboard = true;
      _softwareKeyboardController!.open();

      // Notify delegate listeners.
      notifyListeners();
    });
  }

  /// Hides (doesn't close) the software keyboard, if it's open.
  @override
  void hideSoftwareKeyboard() {
    setState(() {
      _wantsToShowSoftwareKeyboard = false;
      _softwareKeyboardController!.hide();

      // Notify delegate listeners.
      notifyListeners();
    });

    _maybeAnimatePanelClosed();
  }

  /// Whether a keyboard panel should be displayed instead of the software keyboard.
  bool get wantsToShowKeyboardPanel => _wantsToShowKeyboardPanel;
  bool _wantsToShowKeyboardPanel = false;

  @override
  bool get isKeyboardPanelOpen => _wantsToShowKeyboardPanel;

  @override
  PanelType? get openPanel => _activePanel;

  /// Shows the keyboard panel, if it's closed, and hides (doesn't close) the
  /// software keyboard, if it's open.
  @override
  void showKeyboardPanel(PanelType panel) {
    setState(() {
      _wantsToShowKeyboardPanel = true;
      _wantsToShowSoftwareKeyboard = false;
      _activePanel = panel;

      if (_keyboardState == KeyboardState.open) {
        // The keyboard is fully open. We'd like for the panel to immediately
        // appear behind the keyboard as it closes, so that we don't have a
        // bunch of jumping around for the widgets mounted to the top of the
        // keyboard.
        _panelHeightController.value = 1.0;
      } else {
        _panelHeightController.forward();
      }

      _softwareKeyboardController!.hide();

      // Notify delegate listeners.
      notifyListeners();
    });
  }

  /// Hides the keyboard panel, if it's open.
  @override
  void hideKeyboardPanel() {
    setState(() {
      // Close panel.
      _wantsToShowKeyboardPanel = false;
      _activePanel = null;
      _panelHeightController.reverse();

      // Open the keyboard.
      _softwareKeyboardController!.open();

      // Notify delegate listeners.
      notifyListeners();
    });
  }

  /// Closes the software keyboard if it's open, or closes the keyboard panel if
  /// it's open, and fully closes the keyboard (IME) connection.
  @override
  void closeKeyboardAndPanel() {
    setState(() {
      _wantsToShowKeyboardPanel = false;
      _wantsToShowSoftwareKeyboard = false;
      _activePanel = null;
      _softwareKeyboardController!.close();

      // Notify delegate listeners.
      notifyListeners();
    });

    _panelHeightController.reverse();
  }

  void _maybeAnimatePanelClosed() {
    if (_wantsToShowKeyboardPanel || _wantsToShowSoftwareKeyboard || _currentKeyboardHeight != 0.0) {
      return;
    }

    // The user wants to close both the software keyboard and the keyboard panel,
    // but the software keyboard is already closed. Animate the keyboard panel height
    // down to zero.
    _panelHeightController.reverse(from: 1.0);
  }

  /// Updates our local cache of the current bottom window insets, which we assume reflects
  /// the current software keyboard height.
  void _updateKeyboardHeightForCurrentViewInsets() {
    final newBottomInset = MediaQuery.viewInsetsOf(context).bottom;
    _currentKeyboardHeight = newBottomInset;

    switch (_keyboardState) {
      case KeyboardState.open:
        if (newBottomInset >= _bestGuessMaxKeyboardHeight) {
          // Note: On iOS "open" doesn't necessarily mean fully open. I've found
          // that rapidly opening and closing the keyboard results in an "open"
          // message despite the fact that the keyboard didn't make it all the
          // way up.
          _bestGuessMaxKeyboardHeight = newBottomInset;
        }

        if (_wantsToShowSoftwareKeyboard) {
          // Now that the keyboard is fully open, and we want to show the keyboard,
          // ensure that any previously visible panel is gone. We only want to do
          // this if the keyboard fully opens. Otherwise, this state probably
          // represents a rapid toggle between the keyboard and a panel. In that case,
          // leave the panel alone.
          _panelHeightController.value = 0;
          _wantsToShowKeyboardPanel = false;
          _activePanel = null;
        }

        _updateMaxPanelHeight();

        // Notify delegate listeners.
        notifyListeners();

        break;
      case KeyboardState.closed:
        // It was found on the iPad simulator that it was possible to close the minimized keyboard,
        // receive a message that the keyboard was closed, but still have bottom insets that reported
        // the height of the minimized keyboard. To hack around that, we explicitly set the keyboard
        // height to zero, when closed.
        if (_currentKeyboardHeight > 0) {
          _currentKeyboardHeight = 0.0;
          onNextFrame((_) => _updateSafeArea());
        }
        break;
      case KeyboardState.opening:
        // The keyboard is changing size. Update our safe area.
        onNextFrame((_) => _updateSafeArea());
        break;
      case KeyboardState.closing:
        if (!wantsToShowKeyboardPanel) {
          // The keyboard is collapsing and we don't want the keyboard panel to be visible.
          // Follow the keyboard back down.
          _panelHeightController
            ..stop()
            ..value = newBottomInset / _bestGuessMaxKeyboardHeight;
        }

        // The keyboard is changing size. Update our safe area.
        onNextFrame((_) => _updateSafeArea());
        break;
    }

    _currentBottomSpacing.value = max(_panelHeight.value, _currentKeyboardHeight);

    setState(() {
      // Re-build with the various property changes we made above.
    });
  }

  final _listeners = <VoidCallback>{};

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  void notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// Update the bottom insets of the enclosing [KeyboardScaffoldSafeArea].
  void _updateSafeArea() {
    if (_ancestorSafeArea == null) {
      return;
    }

    final bottomPadding = _wantsToShowKeyboardPanel //
        ? 0.0
        : _wantsToShowSoftwareKeyboard //
            ? 0.0
            : MediaQuery.paddingOf(context).bottom;

    final toolbarSize = (_toolbarKey.currentContext?.findRenderObject() as RenderBox?)?.size;
    final bottomInsets = _currentBottomSpacing.value + (toolbarSize?.height ?? 0);

    _ancestorSafeArea!.geometry = _ancestorSafeArea!.geometry.copyWith(
      bottomInsets: bottomInsets,
      bottomPadding: bottomPadding,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shouldShowKeyboardPanel = wantsToShowKeyboardPanel ||
        // The keyboard panel should be kept visible while the software keyboard is expanding
        // and the keyboard panel was previously visible. Otherwise, there will be an empty
        // region between the top of the software keyboard and the bottom of the above-keyboard panel.
        (wantsToShowSoftwareKeyboard && _keyboardState != KeyboardState.open);

    assert(() {
      keyboardPanelLog.fine('''
Building keyboard scaffold
 - keyboard state: $_keyboardState
 - wants to show toolbar? $_wantsToShowToolbar
 - wants to show software keyboard? $wantsToShowSoftwareKeyboard
 - best-guess keyboard height: $_bestGuessMaxKeyboardHeight
 - current keyboard height: $_currentKeyboardHeight
 - wants to show keyboard panel? $wantsToShowKeyboardPanel
 - should show keyboard panel? $shouldShowKeyboardPanel
 - active panel: $_activePanel
 - current panel animation progress: ${_panelHeightController.value}, animation height: ${_panelHeight.value}
 - current bottom spacing: ${_currentBottomSpacing.value}''');

      return true;
    }());

    return OverlayPortal(
      controller: _overlayPortalController,
      overlayChildBuilder: (context) {
        return ValueListenableBuilder(
          valueListenable: _currentBottomSpacing,
          builder: (context, currentHeight, child) {
            if (!_wantsToShowToolbar && !shouldShowKeyboardPanel) {
              return const SizedBox.shrink();
            }

            onNextFrame((_) {
              // Ensure that our latest keyboard height/panel height calculations are
              // accounted for in the ancestor safe area after this layout pass.
              _updateSafeArea();
            });

            return Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_wantsToShowToolbar)
                    KeyedSubtree(
                      key: _toolbarKey,
                      child: widget.toolbarBuilder(
                        context,
                        _activePanel,
                      ),
                    ),
                  // Spacer that pushes the toolbar up above the current bottom spacing,
                  // whether that's the software keyboard, or a panel.
                  AnimatedBuilder(
                    animation: _currentBottomSpacing,
                    builder: (context, child) {
                      return SizedBox(
                        height: _currentBottomSpacing.value,
                        child: child,
                      );
                    },
                    // In the case that we want to display a panel, display it here,
                    // in the current bottom space below the toolbar.
                    child: shouldShowKeyboardPanel ? widget.keyboardPanelBuilder(context, _activePanel) : null,
                  ),
                ],
              ),
            );
          },
        );
      },
      child: widget.contentBuilder(
        context,
        _activePanel,
      ),
    );
  }
}

/// Shows and hides the keyboard panel and software keyboard.
class KeyboardPanelController<PanelType> {
  KeyboardPanelController(
    this._softwareKeyboardController,
  );

  void dispose() {
    detach();
  }

  final SoftwareKeyboardController _softwareKeyboardController;

  KeyboardPanelScaffoldDelegate<PanelType>? _delegate;

  /// Whether this controller is currently attached to a delegate that
  /// knows how to show a toolbar, and open/close the software keyboard
  /// and keyboard panel.
  bool get hasDelegate => _delegate != null;

  /// Attaches this controller to a delegate that knows how to show a toolbar, open and
  /// close the software keyboard, and the keyboard panel.
  void attach(KeyboardPanelScaffoldDelegate<PanelType> delegate) {
    editorImeLog.finer("[KeyboardPanelController] - Attaching to delegate: $delegate");
    _delegate = delegate;
    _delegate!.onAttached(_softwareKeyboardController);
  }

  /// Detaches this controller from its delegate.
  ///
  /// This controller can't open or close the software keyboard, or keyboard panel, while
  /// detached from a delegate that knows how to make that happen.
  void detach() {
    editorImeLog.finer("[KeyboardPanelController] - Detaching from delegate: $_delegate");
    _delegate?.onDetached();
    _delegate = null;
  }

  /// Whether the toolbar should be displayed, anchored to the top of the keyboard area.
  KeyboardToolbarVisibility get toolbarVisibility => _delegate?.toolbarVisibility ?? KeyboardToolbarVisibility.hidden;
  set toolbarVisibility(KeyboardToolbarVisibility value) => _delegate?.toolbarVisibility = value;

  /// Shows the toolbar, if it's hidden, or hides the toolbar, if it's visible.
  void toggleToolbar() => _delegate?.toggleToolbar();

  /// Shows the toolbar that's mounted to the top of the keyboard area.
  void showToolbar() => _delegate?.showToolbar();

  /// Hides the toolbar that's mounted to the top of the keyboard area.
  void hideToolbar() => _delegate?.hideToolbar();

  /// Whether the delegate currently wants a keyboard panel to be open.
  ///
  /// This is expressed as "want" because the keyboard panel has transitory states,
  /// like opening and closing. Therefore, this property doesn't reflect actual
  /// visibility.
  bool get isSoftwareKeyboardOpen => _delegate?.isKeyboardPanelOpen ?? false;

  /// Shows the software keyboard, if it's hidden.
  void showSoftwareKeyboard() {
    _delegate?.showSoftwareKeyboard();
  }

  /// Hides (doesn't close) the software keyboard, if it's open.
  void hideSoftwareKeyboard() {
    _delegate?.hideSoftwareKeyboard();
  }

  /// Whether the delegate currently wants a keyboard panel to be open.
  ///
  /// This is expressed as "want" because the keyboard panel has transitory states,
  /// like opening and closing. Therefore, this property doesn't reflect actual
  /// visibility.
  bool get isKeyboardPanelOpen => _delegate?.isKeyboardPanelOpen ?? false;

  PanelType? get openPanel => _delegate?.openPanel;

  /// Shows the keyboard panel, if it's closed, and hides (doesn't close) the
  /// software keyboard, if it's open.
  void showKeyboardPanel(PanelType panel) => _delegate?.showKeyboardPanel(panel);

  /// Hides the keyboard panel, if it's open.
  void hideKeyboardPanel() {
    _delegate?.hideKeyboardPanel();
  }

  /// Closes the software keyboard if it's open, or closes the keyboard panel if
  /// it's open, and fully closes the keyboard (IME) connection.
  void closeKeyboardAndPanel() {
    _delegate?.closeKeyboardAndPanel();
  }
}

abstract interface class KeyboardPanelScaffoldDelegate<PanelType> implements ChangeNotifier {
  /// Called on this delegate by the [KeyboardPanelController] when the controller
  /// attaches to the delegate.
  ///
  /// [onAttached] is used to pass critical dependencies from the controller to
  /// the delegate.
  void onAttached(SoftwareKeyboardController softwareKeyboardController);

  /// Called on this delegate by the [KeyboardPanelController] when the controller
  /// detaches from the delegate.
  ///
  /// Implementers should release any resources created/stored in [onAttached].
  void onDetached();

  /// The visibility policy for the toolbar that's docked to the top of the software keyboard.
  KeyboardToolbarVisibility get toolbarVisibility;
  set toolbarVisibility(KeyboardToolbarVisibility value);

  /// Shows the toolbar, if it's hidden, or hides the toolbar, if it's visible.
  void toggleToolbar();

  /// Shows the toolbar that's mounted to the top of the keyboard area.
  void showToolbar();

  /// Hides the toolbar that's mounted to the top of the keyboard area.
  void hideToolbar();

  /// Whether this delegate currently wants the software keyboard to be open.
  ///
  /// This is expressed as "want" because the keyboard has transitory states,
  /// like opening and closing. Therefore, this property doesn't reflect actual
  /// visibility.
  bool get isSoftwareKeyboardOpen;

  /// Shows the software keyboard, if it's hidden.
  void showSoftwareKeyboard();

  /// Hides (doesn't close) the software keyboard, if it's open.
  void hideSoftwareKeyboard();

  /// Whether this delegate currently wants a keyboard panel to be open.
  ///
  /// This is expressed as "want" because the keyboard panel has transitory states,
  /// like opening and closing. Therefore, this property doesn't reflect actual
  /// visibility.
  bool get isKeyboardPanelOpen;

  PanelType? get openPanel;

  /// Shows the keyboard panel, if it's closed, and hides (doesn't close) the
  /// software keyboard, if it's open.
  void showKeyboardPanel(PanelType panel);

  /// Hides the keyboard panel, if it's open.
  void hideKeyboardPanel();

  /// Closes the software keyboard if it's open, or closes the keyboard panel if
  /// it's open, and fully closes the keyboard (IME) connection.
  void closeKeyboardAndPanel();
}

enum KeyboardToolbarVisibility {
  /// The toolbar should be hidden.
  hidden,

  /// The toolbar should be visible.
  visible,

  /// The toolbar should be visible only when the software keyboard is open,
  /// or the keyboard panel is open.
  auto,
}

/// Applies padding to the bottom of the child to avoid the software keyboard and
/// the above-keyboard toolbar.
///
/// [KeyboardScaffoldSafeArea] is separate from [KeyboardPanelScaffold] because any
/// widget might want to wrap itself with a [KeyboardPanelScaffold], but the
/// [KeyboardScaffoldSafeArea] needs to be added somewhere in the widget tree that
/// controls the size of the whole screen.
///
/// For example, imagine a social app, like Twitter, that has a text field at the
/// top of the screen to write a post, followed by a social feed below it. The
/// text field would wrap itself with a [KeyboardPanelScaffold] to add a toolbar
/// to the keyboard, but the [KeyboardScaffoldSafeArea] would need to go higher
/// up the widget tree to surround the whole screen.
///
/// The padding in [KeyboardScaffoldSafeArea] is set by a descendant [KeyboardPanelScaffold]
/// in the widget tree.
class KeyboardScaffoldSafeArea extends StatefulWidget {
  static KeyboardScaffoldSafeAreaMutator of(BuildContext context) {
    return maybeOf(context)!;
  }

  static KeyboardScaffoldSafeAreaMutator? maybeOf(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_InheritedKeyboardScaffoldSafeArea>();
    return context.findAncestorStateOfType<_KeyboardScaffoldSafeAreaState>();
  }

  const KeyboardScaffoldSafeArea({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<KeyboardScaffoldSafeArea> createState() => _KeyboardScaffoldSafeAreaState();
}

class _KeyboardScaffoldSafeAreaState extends State<KeyboardScaffoldSafeArea>
    implements KeyboardScaffoldSafeAreaMutator {
  KeyboardSafeAreaGeometry? _keyboardSafeAreaData;

  KeyboardScaffoldSafeAreaMutator? _ancestorSafeArea;
  bool _isSafeAreaFromMediaQuery = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    // Initialize the keyboard insets and padding.
    //
    // First, it's possible that this safe area sits beneath another safe area. In that
    // case, we defer to the ancestor safe area. This makes it possible to create a keyboard
    // safe area in one subtree, and communicate that safe area to another subtree, by
    // sharing an ancestor. For example, consider a widget tree where a chat editor sits in
    // a Stack, and the content sits behind that editor, in the same Stack. In that case,
    // we want to apply a keyboard safe area to the content, but that content is a cousin
    // of the editor, not a direct ancestor or descendant. So we need to be able to coordinate
    // the safe area across independent trees by sharing an ancestor.
    //
    // Example:
    //   KeyboardScaffoldSafeArea
    //    |- Stack
    //       |- KeyboardScaffoldSafeArea
    //          |- Content
    //       |- SuperEditor
    //
    // Second, if there's no existing ancestor KeyboardScaffoldSafeArea, then defer to whatever
    // MediaQuery reports. We only do this for the very first frame because we don't yet
    // know what our values should be (because that's reported by descendants in the tree).
    _ancestorSafeArea = KeyboardScaffoldSafeArea.maybeOf(context);

    if (_keyboardSafeAreaData == null) {
      // This is the first call to didChangeDependencies. Initialize our safe area.
      _keyboardSafeAreaData = KeyboardSafeAreaGeometry(
        bottomInsets: _ancestorSafeArea?.geometry.bottomInsets ?? MediaQuery.viewInsetsOf(context).bottom,
        bottomPadding: _ancestorSafeArea?.geometry.bottomPadding ?? MediaQuery.paddingOf(context).bottom,
      );

      // We track whether our safe area is from MediaQuery (instead of an another KeyboardSafeAreaGeometry).
      // We do this in case the MediaQuery value changes when we don't have any descendant
      // KeyboardPanelScaffold.
      //
      // For example, you're on Screen 1 with the keyboard up. You navigate to Screen 2, which closes the keyboard. When
      // Screen 2 first pumps, it sees that the keyboard is up, so it configures a keyboard safe area. But the keyboard
      // immediately closes. Screen 2 is then stuck with a keyboard safe area that never goes away.
      //
      // By tracking when our safe area comes from MediaQuery, we can continue to honor changing
      // MediaQuery values until a descendant explicitly sets our `geometry`.
      _isSafeAreaFromMediaQuery = _ancestorSafeArea == null;
    }

    if (_isSafeAreaFromMediaQuery) {
      // Our current safe area came from MediaQuery, not a descendant. Therefore,
      // we want to continue blindly honoring the MediaQuery.
      _keyboardSafeAreaData = KeyboardSafeAreaGeometry(
        bottomInsets: MediaQuery.viewInsetsOf(context).bottom,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
    }
  }

  @override
  KeyboardSafeAreaGeometry get geometry => _keyboardSafeAreaData!;

  @override
  set geometry(KeyboardSafeAreaGeometry geometry) {
    _isSafeAreaFromMediaQuery = false;
    if (geometry == _keyboardSafeAreaData) {
      return;
    }

    // Propagate this geometry to any ancestor keyboard safe areas.
    _ancestorSafeArea?.geometry = geometry;

    setStateAsSoonAsPossible(() {
      _keyboardSafeAreaData = geometry;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_ancestorSafeArea != null) {
      // An ancestor safe area was already applied to our subtree.
      return widget.child;
    }

    return _InheritedKeyboardScaffoldSafeArea(
      keyboardSafeAreaData: _keyboardSafeAreaData!,
      child: Padding(
        padding: EdgeInsets.only(bottom: _keyboardSafeAreaData!.bottomInsets),
        // ^ We inject bottom insets to push content above the keyboard. However, we don't
        //   inject the `bottomPadding` because that would take away styling opportunities
        //   from the user. Consider a chat message editor at the bottom of the screen. That
        //   chat editor should push its content up above the bottom notch, but the chat editor
        //   itself should still extend its background to the bottom of the screen. If we
        //   enforce bottom padding here, then the whole chat editor would get pushed up and
        //   and leave an ugly visual gap between the editor and the bottom of the screen.
        child: widget.child,
      ),
    );
  }
}

abstract interface class KeyboardScaffoldSafeAreaMutator {
  KeyboardSafeAreaGeometry get geometry;
  set geometry(KeyboardSafeAreaGeometry geometry);
}

class _InheritedKeyboardScaffoldSafeArea extends InheritedWidget {
  const _InheritedKeyboardScaffoldSafeArea({
    required this.keyboardSafeAreaData,
    required super.child,
  });

  final KeyboardSafeAreaGeometry keyboardSafeAreaData;

  @override
  bool updateShouldNotify(covariant _InheritedKeyboardScaffoldSafeArea oldWidget) {
    return oldWidget.keyboardSafeAreaData != keyboardSafeAreaData;
  }
}

/// Insets applied by a [KeyboardPanelScaffold] to an ancestor [KeyboardScaffoldSafeArea]
/// to deal with the presence or absence of the software keyboard.
class KeyboardSafeAreaGeometry {
  const KeyboardSafeAreaGeometry({
    this.bottomInsets = 0,
    this.bottomPadding = 0,
  });

  /// The space taken up by the keyboard or a keyboard panel.
  final double bottomInsets;

  /// The space taken up by the bottom notch of the OS, but only when the IME
  /// connection is closed.
  ///
  /// This property is our version of `MediaQuery.paddingOf(context).bottom`.
  /// The standard `MediaQuery` value can't be used because the rules for when
  /// to apply the bottom padding is different in an app that shows keyboard
  /// panels.
  ///
  /// There are 3 possible visual states that are relevant to the bottom notch
  /// padding:
  ///
  ///  1. Regular UI - no keyboard visible, no keyboard panel visible.
  ///  2. Keyboard open.
  ///  3. Keyboard panel open (keyboard closed).
  ///
  /// When displaying regular UI (#1), content should be pushed up above the
  /// bottom notch so that it's clearly visible, and interactable. `SafeArea`
  /// does this for you by default. But we can't use `SafeArea` because the
  /// rules for when to apply bottom notch padding is different when showing
  /// keyboard panels. Therefore, users of this scaffold must apply this
  /// padding themselves. This property follows the rules needed for expected
  /// behavior when showing keyboard panels. Use this property instead of
  /// `SafeArea` and instead of `MediaQuery.paddingOf(context).bottom`.
  ///
  /// When displaying the keyboard (#2), the OS consumes its own notch height,
  /// so no additional padding is needed. If you push above the keyboard, then
  /// you automatically push above the notch. `SafeArea` does this automatically
  /// but we can't use `SafeArea` because the padding rules for the keyboard
  /// panel are different.
  ///
  /// The major difference we need to handle is when a keyboard panel is open (#3).
  /// This is the situation that Flutter doesn't handle correctly, because Flutter
  /// doesn't have a concept of keyboard panels. In the case of a keyboard panel,
  /// the keyboard is closed, but we don't want to push the content up above the
  /// notch. This is because the keyboard panel, itself, covers the notch. It's
  /// the same situation as when the keyboard is up, except the keyboard is closed
  /// and a keyboard panel is up. In this situation, we want bottom padding to
  /// be zero, instead of bottom padding that pushes above the notch.
  ///
  /// By blindly applying this padding to your content, you will get the desired
  /// bottom padding at the relevant time.
  final double bottomPadding;

  KeyboardSafeAreaGeometry copyWith({
    double? bottomInsets,
    double? bottomPadding,
  }) {
    return KeyboardSafeAreaGeometry(
      bottomInsets: bottomInsets ?? this.bottomInsets,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KeyboardSafeAreaGeometry &&
          runtimeType == other.runtimeType &&
          bottomInsets == other.bottomInsets &&
          bottomPadding == other.bottomPadding;

  @override
  int get hashCode => bottomInsets.hashCode ^ bottomPadding.hashCode;
}