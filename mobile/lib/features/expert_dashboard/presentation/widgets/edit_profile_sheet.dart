import 'package:flutter/material.dart';

import '../../../../core/theme/zitlas_tokens.dart';
import '../../expert_dashboard_controller.dart';
import '../../models/expert_models.dart';

/// `#epModalBackdrop` / `saveProfile()` (ED:2652-2773). Same fields, same
/// validation (name required, fee numeric, years non-negative, `%`
/// auto-appended to success rate) and the same merge-write to
/// `experts/{uid}` restricted to editable fields.
Future<void> showEditProfileSheet(
  BuildContext context,
  ExpertDashboardController controller,
  ExpertProfile profile,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _EditProfileSheet(controller: controller, profile: profile),
  );
}

class _EditProfileSheet extends StatefulWidget {
  const _EditProfileSheet({required this.controller, required this.profile});

  final ExpertDashboardController controller;
  final ExpertProfile profile;

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _specialization = TextEditingController(text: widget.profile.specialization);
  late final _title = TextEditingController(text: widget.profile.title);
  late final _bio = TextEditingController(text: widget.profile.bio);
  late final _quote = TextEditingController(text: widget.profile.quote);
  late final _experience = TextEditingController(text: widget.profile.experience);
  late final _successRate = TextEditingController(text: widget.profile.successRate);
  late final _clients = TextEditingController(text: widget.profile.clients);
  late final _sessions = TextEditingController(text: widget.profile.sessions);
  late final _fee = TextEditingController(text: '${widget.profile.fee}');
  late final _duration = TextEditingController(text: '${widget.profile.sessionDuration}');
  /// Round-tripped untouched. The Flutter dot no longer reads it, but the
  /// website still renders `experts/{uid}.status`, so saving the profile
  /// must not silently clear a field another client depends on.
  late final String _status = widget.profile.status;

  bool _saving = false;
  String? _nameError;
  String? _feeError;

  @override
  void dispose() {
    for (final c in [
      _name,
      _specialization,
      _title,
      _bio,
      _quote,
      _experience,
      _successRate,
      _clients,
      _sessions,
      _fee,
      _duration,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _nameError = null;
      _feeError = null;
    });

    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = 'Name is required');
      return;
    }

    final fee = int.tryParse(_fee.text.trim());
    if (fee == null || fee < 0) {
      setState(() => _feeError = 'Must be a valid number');
      return;
    }

    // Website appends '%' when the expert omits it (ED:2684-2687).
    var success = _successRate.text.trim();
    if (success.isNotEmpty && !success.contains('%')) success = '$success%';

    // Duration parsed to whole minutes, defaulting to 25 (ED:2690).
    final duration = int.tryParse(_duration.text.trim().replaceAll(RegExp(r'[^0-9]'), '')) ?? 25;

    setState(() => _saving = true);
    try {
      await widget.controller.saveProfile(
        widget.profile.copyWith(
          name: name,
          specialization: _specialization.text.trim(),
          title: _title.text.trim(),
          bio: _bio.text.trim(),
          quote: _quote.text.trim(),
          experience: _experience.text.trim(),
          successRate: success,
          clients: _clients.text.trim(),
          sessions: _sessions.text.trim(),
          fee: fee,
          sessionDuration: duration,
          status: _status,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated!')),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save your profile. Please try again.")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: const BoxDecoration(
            color: ZitlasTokens.bgStart,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: ZitlasTokens.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Edit Profile',
                        style: TextStyle(
                          color: ZitlasTokens.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: ZitlasTokens.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: [
                    _Field(label: 'Name', controller: _name, error: _nameError, required: true),
                    _Field(
                      label: 'Specialization',
                      controller: _specialization,
                      hint: 'e.g. Weight Loss Nutritionist',
                    ),
                    _Field(
                      label: 'Title / Credential',
                      controller: _title,
                      hint: 'e.g. Certified Weight-Loss Specialist',
                    ),
                    _Field(
                      label: 'Bio / Description',
                      controller: _bio,
                      hint: 'Tell athletes about your expertise…',
                      maxLines: 3,
                    ),
                    _Field(
                      label: 'Motivational Quote',
                      controller: _quote,
                      hint: 'A quote that defines you…',
                    ),
                    const _GroupLabel('Stats & Experience'),
                    Row(
                      children: [
                        Expanded(
                          child: _Field(
                            label: 'Years of Experience',
                            controller: _experience,
                            hint: 'e.g. 9+',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Field(
                            label: 'Success Rate',
                            controller: _successRate,
                            hint: 'e.g. 97%',
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: _Field(
                            label: 'Clients Served',
                            controller: _clients,
                            hint: 'e.g. 900+',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Field(
                            label: 'Sessions Completed',
                            controller: _sessions,
                            hint: 'e.g. 1.4K+',
                          ),
                        ),
                      ],
                    ),
                    const _GroupLabel('Fees & Availability'),
                    Row(
                      children: [
                        Expanded(
                          child: _Field(
                            label: 'Review Fee (₹)',
                            controller: _fee,
                            hint: 'e.g. 249',
                            error: _feeError,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _Field(
                            label: 'Session (min)',
                            controller: _duration,
                            hint: 'e.g. 25',
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    // The manual Online/Offline pair that used to live here
                    // is gone. It was the only thing that ever changed the
                    // dot, so an expert who never opened this sheet showed
                    // as online permanently — including months after their
                    // last sign-in. Presence is now derived from a live
                    // heartbeat (`core/presence/`) and needs no input.
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'Your Online status updates automatically while you '
                        'have ZITLAS open.',
                        style: TextStyle(
                          color: ZitlasTokens.textMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _saving ? null : () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: ZitlasTokens.textSecondary,
                            side: const BorderSide(color: ZitlasTokens.borderSub),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(kZitlasRadiusSm),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: _saving ? null : _save,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ZitlasTokens.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(kZitlasRadiusSm),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Save Changes'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: ZitlasTokens.primary,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.error,
    this.maxLines = 1,
    this.keyboardType,
    this.required = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? error;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool required;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: label,
              children: required
                  ? const [TextSpan(text: ' *', style: TextStyle(color: ZitlasTokens.danger))]
                  : null,
            ),
            style: const TextStyle(
              color: ZitlasTokens.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            maxLines: maxLines,
            keyboardType: keyboardType,
            style: const TextStyle(color: ZitlasTokens.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: ZitlasTokens.bgCard,
              hintText: hint,
              hintStyle: const TextStyle(color: ZitlasTokens.textMuted, fontSize: 13),
              errorText: error,
              contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ZitlasTokens.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ZitlasTokens.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ZitlasTokens.primary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
