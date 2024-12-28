import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'suggestions_box_controller.dart';
import 'text_cursor.dart';

typedef ChipsInputSuggestions<T> = FutureOr<List<T>> Function(String query);
typedef ChipSelected<T> = void Function(T data, bool selected);
typedef ChipsBuilder<T> = Widget Function(
    BuildContext context, ChipsInputState<T> state, T data);

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
  })  : assert(maxChips == null || initialValue.length <= maxChips),
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

  final TextCapitalization textCapitalization;

  @override
  ChipsInputState<T> createState() => ChipsInputState<T>();
}

class ChipsInputState<T> extends State<ChipsInput<T>> implements TextInputClient {
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
                            )
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

  void selectSuggestion(T data) {
    if (!_hasReachedMaxChips) {
      setState(() => _chips = _chips..add(data));
      if (widget.allowChipEditing) {
        final enteredText = _value.normalCharactersText;
        if (enteredText.isNotEmpty) _enteredTexts[data] = enteredText;
      }
      _updateTextInputState(replaceText: true);
      setState(() => _suggestions = null);
      _suggestionsStreamController.add(_suggestions);
      if (_hasReachedMaxChips) _suggestionsBoxController.close();
      widget.onChanged(_chips.toList(growable: false));
    } else {
      _suggestionsBoxController.close();
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
        await Scrollable.of(context)?.position.ensureVisible(renderBox);
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
    if (!_suggestionsBoxController.isOpened) {
      _suggestionsBoxController.open();
    }
  }

  @override
  void didChangeInputControl(
      TextInputControl? oldControl, TextInputControl? newControl) {
    // Si nécessaire, implémentez des actions sur les changements de contrôle
  }

  @override
  void insertContent(KeyboardInsertedContent content) {
    // Implémentez la logique d'insertion de contenu si nécessaire
  }

  @override
  void performSelector(String selectorName) {
    // Implémentez la logique d'exécution d'actions spécifiques si nécessaire
  }

  void _updateTextInputState({bool replaceText = false}) {
    if (_hasInputConnection) {
      final replacementText = _chips.isEmpty
          ? ''
          : _chips
              .map((e) => widget.chipBuilder(context, this, e))
              .join('');
      final text = TextEditingValue(
        text: replacementText,
        selection: TextSelection.collapsed(offset: replacementText.length),
      );
      _textInputConnection?.setEditingState(text);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_hasInputConnection) {
      _textInputConnection?.close();
      _textInputConnection = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _effectiveFocusNode,
      child: GestureDetector(
        onTap: requestKeyboard,
        child: CompositedTransformTarget(
          link: _layerLink,
          child: InputDecorator(
            decoration: widget.decoration.copyWith(
              hintText: widget.decoration.hintText,
              enabled: widget.enabled,
            ),
            child: Row(
              children: [
                ..._chips.map((e) => widget.chipBuilder(context, this, e)),
                Flexible(
                  child: TextField(
                    controller: TextEditingController.fromValue(_value),
                    focusNode: _effectiveFocusNode,
                    decoration: InputDecoration(
                      border: InputBorder.none,
                    ),
                    style: widget.textStyle,
                    onChanged: _onSearchChanged,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void connectionClosed() {
    // TODO: implement connectionClosed
  }
  
  @override
  // TODO: implement currentAutofillScope
  AutofillScope? get currentAutofillScope => throw UnimplementedError();
  
  @override
  // TODO: implement currentTextEditingValue
  TextEditingValue? get currentTextEditingValue => throw UnimplementedError();
  
  @override
  void insertTextPlaceholder(Size size) {
    // TODO: implement insertTextPlaceholder
  }
  
  @override
  void performAction(TextInputAction action) {
    // TODO: implement performAction
  }
  
  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // TODO: implement performPrivateCommand
  }
  
  @override
  void removeTextPlaceholder() {
    // TODO: implement removeTextPlaceholder
  }
  
  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // TODO: implement showAutocorrectionPromptRect
  }
  
  @override
  void showToolbar() {
    // TODO: implement showToolbar
  }
  
  @override
  void updateEditingValue(TextEditingValue value) {
    // TODO: implement updateEditingValue
  }
  
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // TODO: implement updateFloatingCursor
  }
}
