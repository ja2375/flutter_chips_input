import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'suggestions_box_controller.dart';
import 'text_cursor.dart';

typedef ChipsInputSuggestions<T> = FutureOr<List<T>> Function(String query);
typedef ChipSelected<T> = void Function(T data, bool selected);
typedef ChipsBuilder<T> = Widget Function(
    BuildContext context, ChipsInputState<T> state, T data, bool selected);
typedef OnEditingCompleteCallback = void Function(List<String> chipValues);

const kObjectReplacementChar = 0xFFFD;

extension on TextEditingValue {
  String get normalCharactersText => String.fromCharCodes(
        text.codeUnits.where((ch) => ch != kObjectReplacementChar),
      );

  List<int> get replacementCharacters => text.codeUnits
      .where((ch) => ch == kObjectReplacementChar)
      .toList(growable: false);

  int get replacementCharactersCount => replacementCharacters.length;
}

class ChipsInput<T> extends StatefulWidget {
  const ChipsInput({
    Key? key,
    this.initialValue = const [],
    this.decoration = const InputDecoration(),
    this.enabled = true,
    required this.chipBuilder,
    required this.suggestionBuilder,
    required this.findSuggestions,
    required this.onChanged,
    this.maxChips,
    this.textStyle,
    this.suggestionsBoxMaxHeight,
    this.inputType = TextInputType.text,
    this.textOverflow = TextOverflow.clip,
    this.obscureText = false,
    this.autocorrect = true,
    this.actionLabel,
    this.inputAction = TextInputAction.done,
    this.keyboardAppearance = Brightness.light,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = false,
    this.allowChipEditing = false,
    this.focusNode,
    this.initialSuggestions,
    this.multichoiceCharSeparator,
    this.keyValueEnabled = false,
    this.onEditingComplete,
  })  : assert(maxChips == null || initialValue.length <= maxChips),
        assert(!keyValueEnabled ||
            (keyValueEnabled && multichoiceCharSeparator != null)),
        super(key: key);

  final InputDecoration decoration;
  final TextStyle? textStyle;
  final bool enabled;
  final ChipsInputSuggestions<T> findSuggestions;
  final ValueChanged<List<T>> onChanged;
  final ChipsBuilder<T> chipBuilder;
  final ChipsBuilder<T> suggestionBuilder;
  final List<T> initialValue;
  final int? maxChips;
  final double? suggestionsBoxMaxHeight;
  final TextInputType inputType;
  final TextOverflow textOverflow;
  final bool obscureText;
  final bool autocorrect;
  final String? actionLabel;
  final TextInputAction inputAction;
  final Brightness keyboardAppearance;
  final bool autofocus;
  final bool allowChipEditing;
  final FocusNode? focusNode;
  final List<T>? initialSuggestions;
  final String? multichoiceCharSeparator;
  final bool keyValueEnabled;
  final OnEditingCompleteCallback? onEditingComplete;

  // final Color cursorColor;

  final TextCapitalization textCapitalization;

  @override
  ChipsInputState<T> createState() => ChipsInputState<T>();
}

class ChipsInputState<T> extends State<ChipsInput<T>>
    implements TextInputClient {
  Set<T> _chips = <T>{};
  List<T?>? _suggestions;
  final StreamController<List<T?>?> _suggestionsStreamController =
      StreamController<List<T>?>.broadcast();
  int _searchId = 0;
  TextEditingValue _value = const TextEditingValue();
  TextInputConnection? _textInputConnection;
  late SuggestionsBoxController _suggestionsBoxController;
  final _layerLink = LayerLink();
  final Map<T?, String> _enteredTexts = <T, String>{};
  int? _selectedSuggestionIndex;

  TextInputConfiguration get textInputConfiguration => TextInputConfiguration(
        inputType: widget.inputType,
        obscureText: widget.obscureText,
        autocorrect: widget.autocorrect,
        actionLabel: widget.actionLabel,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        textCapitalization: widget.textCapitalization,
      );

  bool get _hasInputConnection =>
      _textInputConnection != null && _textInputConnection!.attached;

  bool get _hasReachedMaxChips =>
      widget.maxChips != null && _chips.length >= widget.maxChips!;

  int? get selectedSuggestionIndex => _selectedSuggestionIndex;

  FocusNode? _focusNode;
  FocusNode get _effectiveFocusNode =>
      widget.focusNode ?? (_focusNode ??= FocusNode());
  late FocusAttachment _nodeAttachment;

  RenderBox? get renderBox => context.findRenderObject() as RenderBox?;

  bool get _canRequestFocus => widget.enabled;

  @override
  void initState() {
    super.initState();
    _chips.addAll(widget.initialValue);
    _suggestions = widget.initialSuggestions
        ?.where((r) => !_chips.contains(r))
        .toList(growable: false);
    _suggestionsBoxController = SuggestionsBoxController(context);

    _effectiveFocusNode.addListener(_handleFocusChanged);
    _nodeAttachment = _effectiveFocusNode.attach(context);
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _initOverlayEntry();
      if (mounted && widget.autofocus) {
        FocusScope.of(context).autofocus(_effectiveFocusNode);
      }
    });
  }

  @override
  void dispose() {
    _closeInputConnectionIfNeeded();
    _effectiveFocusNode.removeListener(_handleFocusChanged);
    _focusNode?.dispose();
    _suggestionsStreamController.close();
    _suggestionsBoxController.close();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (_selectedSuggestionIndex != null) {
      _selectedSuggestionIndex = null;
    }
    if (_effectiveFocusNode.hasFocus) {
      _openInputConnection();
      _suggestionsBoxController.open();
    } else {
      _closeInputConnectionIfNeeded();
      _suggestionsBoxController.close();
    }
    if (mounted) {
      setState(() {
        /*rebuild so that _TextCursor is hidden.*/
      });
    }
  }

  void requestKeyboard() {
    if (_effectiveFocusNode.hasFocus) {
      _openInputConnection();
    } else {
      FocusScope.of(context).requestFocus(_effectiveFocusNode);
    }
  }

  void _initOverlayEntry() {
    _suggestionsBoxController.overlayEntry = OverlayEntry(
      builder: (context) {
        final size = renderBox!.size;
        final renderBoxOffset = renderBox!.localToGlobal(Offset.zero);
        final topAvailableSpace = renderBoxOffset.dy;
        final mq = MediaQuery.of(context);
        final bottomAvailableSpace = mq.size.height -
            mq.viewInsets.bottom -
            renderBoxOffset.dy -
            size.height;
        var suggestionBoxHeight = max(topAvailableSpace, bottomAvailableSpace);
        if (null != widget.suggestionsBoxMaxHeight) {
          suggestionBoxHeight =
              min(suggestionBoxHeight, widget.suggestionsBoxMaxHeight!);
        }
        final showTop = topAvailableSpace > bottomAvailableSpace;
        // print("showTop: $showTop" );
        final compositedTransformFollowerOffset =
            showTop ? Offset(0, -size.height) : Offset.zero;

        return StreamBuilder<List<T?>?>(
          stream: _suggestionsStreamController.stream,
          initialData: _suggestions,
          builder: (context, snapshot) {
            if (snapshot.hasData && snapshot.data!.isNotEmpty) {
              final suggestionsListView = Material(
                elevation: 0,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: suggestionBoxHeight,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: snapshot.data!.length,
                    itemBuilder: (BuildContext context, int index) {
                      return _suggestions != null
                          ? widget.suggestionBuilder(
                              context,
                              this,
                              _suggestions![index] as T,
                              _selectedSuggestionIndex == index)
                          : Container();
                    },
                  ),
                ),
              );
              return Positioned(
                width: size.width,
                child: CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  offset: compositedTransformFollowerOffset,
                  child: !showTop
                      ? suggestionsListView
                      : FractionalTranslation(
                          translation: const Offset(0, -1),
                          child: suggestionsListView,
                        ),
                ),
              );
            }
            return Container();
          },
        );
      },
    );
  }

  void selectSuggestion(dynamic data) {
    if (_selectedSuggestionIndex != null) {
      _selectedSuggestionIndex = null;
    }
    if (!_hasReachedMaxChips) {
      if (!widget.keyValueEnabled ||
          widget.multichoiceCharSeparator == null ||
          (widget.multichoiceCharSeparator != null &&
              data.toString().endsWith(widget.multichoiceCharSeparator!))) {
        _addChip(data);
      } else if (widget.keyValueEnabled &&
          data.toString().contains(':') &&
          data.toString().endsWith(widget.multichoiceCharSeparator!)) {
        _addChip(data);
      }
      _updateTextInputState(
        replaceText: true,
        putText: widget.keyValueEnabled &&
                widget.multichoiceCharSeparator != null &&
                !data.toString().endsWith(widget.multichoiceCharSeparator!)
            ? '${data}: '
            : '',
      );
      setState(() => _suggestions = null);
      _suggestionsStreamController.add(_suggestions);
      if (_hasReachedMaxChips) _suggestionsBoxController.close();
      widget.onChanged(_chips.toList(growable: false));
    } else {
      _suggestionsBoxController.close();
    }
  }

  void _addChip(dynamic data) {
    if (data is String && widget.multichoiceCharSeparator != null) {
      data = data.toString().replaceFirst(widget.multichoiceCharSeparator!, '');
    }

    /// Remove charCode 65533 that gets stragely
    /// generated in some cases and results in a non-printable
    /// charater when parsed to string, as it is not UTF-8
    /// encodable.
    if (data.toString().codeUnits.contains(kObjectReplacementChar)) {
      var codeUnits = List<int>.from(data.toString().codeUnits);
      codeUnits.removeWhere((element) => element == kObjectReplacementChar);
      data = String.fromCharCodes(codeUnits);
    }
    setState(() => _chips.add(data));
    if (widget.allowChipEditing) {
      final enteredText = _value.normalCharactersText;
      if (enteredText.isNotEmpty) _enteredTexts[data] = enteredText;
    }
  }

  void deleteChip(T data) {
    if (widget.enabled) {
      setState(() => _chips.remove(data));
      if (_enteredTexts.containsKey(data)) _enteredTexts.remove(data);
      _updateTextInputState();
      widget.onChanged(_chips.toList(growable: false));
    }
  }

  void _openInputConnection() {
    if (!_hasInputConnection) {
      _textInputConnection = TextInput.attach(this, textInputConfiguration);
      _textInputConnection!.show();
      _updateTextInputState();
    } else {
      _textInputConnection?.show();
    }

    _scrollToVisible();
  }

  void _scrollToVisible() {
    Future.delayed(const Duration(milliseconds: 300), () {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final renderBox = context.findRenderObject() as RenderBox;
        await Scrollable.of(context).position.ensureVisible(renderBox);
      });
    });
  }

  void _onSearchChanged(String value) async {
    final localId = ++_searchId;
    final results = await widget.findSuggestions(value);
    if (_searchId == localId && mounted) {
      setState(() => _suggestions =
          results.where((r) => !_chips.contains(r)).toList(growable: false));
    }
    _suggestionsStreamController.add(_suggestions ?? []);
    if (!_suggestionsBoxController.isOpened && !_hasReachedMaxChips) {
      _suggestionsBoxController.open();
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_hasInputConnection) {
      _textInputConnection!.close();
      _textInputConnection = null;
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    //print("updateEditingValue FIRED with ${value.text}");
    // _receivedRemoteTextEditingValue = value;
    if (widget.multichoiceCharSeparator != null &&
        value.text.endsWith(widget.multichoiceCharSeparator!)) {
      selectSuggestion(value.text);
      return;
    }
    final oldTextEditingValue = _value;
    if (value.text != oldTextEditingValue.text) {
      setState(() => _value = value);
      if (value.replacementCharactersCount <
          oldTextEditingValue.replacementCharactersCount) {
        final removedChip = _chips.last;
        setState(() =>
            _chips = Set.of(_chips.take(value.replacementCharactersCount)));
        widget.onChanged(_chips.toList(growable: false));
        String? putText = '';
        if (widget.allowChipEditing && _enteredTexts.containsKey(removedChip)) {
          putText = _enteredTexts[removedChip]!;
          _enteredTexts.remove(removedChip);
        }
        _updateTextInputState(putText: putText);
      } else {
        _updateTextInputState();
      }
      if (!widget.keyValueEnabled ||
          !(widget.keyValueEnabled &&
              _value.normalCharactersText.contains(':'))) {
        _onSearchChanged(_value.normalCharactersText);
      }
    }
  }

  void _updateTextInputState({replaceText = false, putText = ''}) {
    if (replaceText || putText != '') {
      final updatedText =
          String.fromCharCodes(_chips.map((_) => kObjectReplacementChar)) +
              (replaceText ? '' : _value.normalCharactersText) +
              putText;
      setState(() => _value = _value.copyWith(
            text: updatedText,
            selection: TextSelection.collapsed(offset: updatedText.length),
            //composing: TextRange(start: 0, end: text.length),
            composing: TextRange.empty,
          ));
    }
    _closeInputConnectionIfNeeded(); // Hack for #34 (https://github.com/danvick/flutter_chips_input/issues/34#issuecomment-684505282). TODO: Find permanent fix
    _textInputConnection ??= TextInput.attach(this, textInputConfiguration);
    _textInputConnection?.setEditingState(_value);
    _textInputConnection?.show();
  }

  @override
  void performAction(TextInputAction action) {
    switch (action) {
      case TextInputAction.done:
      case TextInputAction.go:
      case TextInputAction.send:
      case TextInputAction.search:
        if (!widget.keyValueEnabled) {
          if (_suggestions?.isNotEmpty ?? false) {
            if (_selectedSuggestionIndex == null) {
              selectSuggestion(_suggestions!.first as T);
            }
          } else {
            _effectiveFocusNode.unfocus();
          }
        } else {
          /// Add a trailing comma in order for [selectSuggestion]
          /// to actually add the chip & strip out remaining [kObjectReplacementChar].
          var currentText = '${currentTextEditingValue.text},';
          final codeUnits = List<int>.from(currentText.codeUnits);
          if (codeUnits.contains(kObjectReplacementChar)) {
            codeUnits.removeWhere((e) => e == kObjectReplacementChar);
            currentText = String.fromCharCodes(codeUnits);
          }

          /// If there's text (currentText is not empty),
          /// add the chip.
          /// This should prevent the addition of empty chips.
          if (currentText != ',') {
            if (_selectedSuggestionIndex == null) {
              selectSuggestion(currentText);
            }
          }
        }
        if (widget.onEditingComplete != null) {
          var chipValues = _chips.map((e) => e.toString()).toList();
          widget.onEditingComplete!(chipValues);
        }
        break;
      default:
        _effectiveFocusNode.unfocus();
        break;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    //TODO
  }

  @override
  void didUpdateWidget(covariant ChipsInput<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _effectiveFocusNode.canRequestFocus = _canRequestFocus;
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print(point);
  }

  @override
  void connectionClosed() {
    //print('TextInputClient.connectionClosed()');
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  Widget build(BuildContext context) {
    _nodeAttachment.reparent();
    final chipsChildren = _chips
        .map<Widget>((data) => widget.chipBuilder(context, this, data, false))
        .toList();

    final theme = Theme.of(context);

    chipsChildren.add(
      SizedBox(
        height: 30.0,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Flexible(
              flex: 1,
              child: Text(
                _value.normalCharactersText,
                maxLines: 1,
                overflow: widget.textOverflow,
                style: widget.textStyle ??
                    theme.textTheme.titleMedium!.copyWith(height: 1.5),
              ),
            ),
            Flexible(
              flex: 0,
              child: TextCursor(resumed: _effectiveFocusNode.hasFocus),
            ),
          ],
        ),
      ),
    );

    return RawKeyboardListener(
      focusNode: _focusNode ?? FocusNode(),
      onKey: (event) {
        final str = currentTextEditingValue.text;
        if (event.runtimeType == RawKeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.backspace &&
              str.isNotEmpty) {
            final sd = str.substring(0, str.length - 1);
            updateEditingValue(TextEditingValue(
                text: sd,
                selection: TextSelection.collapsed(offset: sd.length)));
          }
          if (_suggestions?.isNotEmpty ?? false) {
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              if (_selectedSuggestionIndex == null) {
                _selectedSuggestionIndex = 0;
              } else {
                if (_selectedSuggestionIndex! + 1 < _suggestions!.length) {
                  _selectedSuggestionIndex = _selectedSuggestionIndex! + 1;
                } else {
                  _selectedSuggestionIndex = 0;
                }
              }
              _suggestionsBoxController.overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              if (_selectedSuggestionIndex == null) {
                _selectedSuggestionIndex = _suggestions!.length - 1;
              } else {
                if (_selectedSuggestionIndex! - 1 > 0) {
                  _selectedSuggestionIndex = _selectedSuggestionIndex! - 1;
                } else {
                  _selectedSuggestionIndex = _suggestions!.length - 1;
                }
              }
              _suggestionsBoxController.overlayEntry!.markNeedsBuild();
            } else if (event.logicalKey == LogicalKeyboardKey.enter) {
              if (_selectedSuggestionIndex != null) {
                selectSuggestion(_suggestions![_selectedSuggestionIndex!]);
              }
            }
          }
        }
      },
      child: NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (SizeChangedLayoutNotification val) {
          if (_selectedSuggestionIndex != null) {
            _selectedSuggestionIndex = null;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            _suggestionsBoxController.overlayEntry?.markNeedsBuild();
          });
          return true;
        },
        child: SizeChangedLayoutNotifier(
          child: Column(
            children: <Widget>[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  requestKeyboard();
                },
                child: InputDecorator(
                  decoration: widget.decoration,
                  isFocused: _effectiveFocusNode.hasFocus,
                  isEmpty: _value.text.isEmpty && _chips.isEmpty,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4.0,
                    runSpacing: 4.0,
                    children: chipsChildren,
                  ),
                ),
              ),
              CompositedTransformTarget(
                link: _layerLink,
                child: Container(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void showToolbar() {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void performSelector(String selectorName) {}
}
