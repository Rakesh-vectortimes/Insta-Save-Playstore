import 'package:flutter/material.dart';

import '../core/constants.dart';

class UrlInputField extends StatefulWidget {
  const UrlInputField({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.hintText = 'Paste Instagram link here...',
    this.enabled = true,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final String hintText;
  final bool enabled;

  @override
  State<UrlInputField> createState() => _UrlInputFieldState();
}

class _UrlInputFieldState extends State<UrlInputField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => widget.onSubmit(),
      decoration: InputDecoration(
        hintText: widget.hintText,
        prefixIcon: const Icon(Icons.link, color: AppColors.primary),
        suffixIcon: widget.controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: widget.enabled ? widget.controller.clear : null,
              )
            : null,
      ),
    );
  }
}
