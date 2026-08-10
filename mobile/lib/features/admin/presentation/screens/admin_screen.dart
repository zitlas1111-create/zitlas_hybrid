import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../../../app/theme.dart';
import '../../../../core/utils/safe_image.dart';
import '../../../../core/widgets/error_view.dart';
import '../../../../core/widgets/loading_view.dart';
import '../../admin_controller.dart';
import '../../data/admin_repository.dart';

/// Native rebuild of the website's admin certificate console
/// (`pages/admin/admin-review.js` + `cert-audit.html`): review pending expert
/// certificates and approve/reject them. Claim-gated (backend `admin` custom
/// claim) and routed entirely through `/api/admin/*` — identical backend,
/// Firestore, permissions, and business logic as the web console.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  /// Reject reasons — verbatim from `certificate-manager.js` REJECT_REASONS.
  static const rejectReasons = <String>[
    'Fake Certificate',
    'Image Too Blurry',
    'Document Not Readable',
    'Wrong Document Uploaded',
    'Expired Certificate',
    'Edited Certificate',
    'Other',
  ];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AdminController>(
      create: (_) => AdminController(
        AdminRepository(firestore: FirebaseFirestore.instance, auth: FirebaseAuth.instance),
      ),
      child: const _AdminBody(),
    );
  }
}

class _AdminBody extends StatelessWidget {
  const _AdminBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AdminController>();
    return Scaffold(
      backgroundColor: ZitlasColors.bgPrimary,
      appBar: AppBar(
        backgroundColor: ZitlasColors.bgPrimary,
        title: const Text('Certificate Review'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: ZitlasColors.textPrimary),
          onPressed: () => context.canPop() ? context.pop() : context.go('/profile'),
        ),
      ),
      body: _body(context, c),
    );
  }

  Widget _body(BuildContext context, AdminController c) {
    if (c.loading) return const LoadingView(message: 'Loading review queue…');
    if (!c.isAdmin) return const _AccessDenied();
    if (c.error != null) return ErrorView(error: c.error!);
    if (c.certs.isEmpty) return const _EmptyState();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      itemCount: c.certs.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (_, i) => _CertCard(cert: c.certs[i]),
    );
  }
}

class _AccessDenied extends StatelessWidget {
  const _AccessDenied();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, color: ZitlasColors.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(
              'Admins only.\nThis area requires an administrator account.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('✅', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(
              'All caught up — no certificates awaiting review.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _CertCard extends StatelessWidget {
  const _CertCard({required this.cert});
  final AdminCert cert;

  Future<void> _approve(BuildContext context) async {
    final c = context.read<AdminController>();
    final err = await c.approve(cert.certId);
    if (context.mounted) {
      _toast(context, err ?? 'Certificate approved — expert marked verified.');
    }
  }

  Future<void> _reject(BuildContext context) async {
    final reason = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZitlasColors.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Reject certificate — reason',
                    style: TextStyle(color: ZitlasColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 15)),
              ),
            ),
            for (final r in AdminScreen.rejectReasons)
              ListTile(
                title: Text(r, style: const TextStyle(color: ZitlasColors.textPrimary)),
                onTap: () => Navigator.of(ctx).pop(r),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (reason == null) return;
    if (!context.mounted) return;
    final c = context.read<AdminController>();
    final err = await c.reject(cert.certId, reason);
    if (context.mounted) {
      _toast(context, err ?? 'Certificate rejected.');
    }
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final busy = context.watch<AdminController>().isBusy(cert.certId);
    return Container(
      decoration: BoxDecoration(
        color: ZitlasColors.bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ZitlasColors.border),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cert.certificateName ?? 'Certificate',
            style: const TextStyle(color: ZitlasColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 15),
          ),
          const SizedBox(height: 4),
          Text(
            'Expert: ${cert.expertName ?? cert.expertId}'
            '${cert.issuingOrganization != null ? '  ·  ${cert.issuingOrganization}' : ''}',
            style: const TextStyle(color: ZitlasColors.textSecondary, fontSize: 12.5),
          ),
          if (cert.verificationScore != null) ...[
            const SizedBox(height: 2),
            Text('AI score: ${cert.verificationScore}',
                style: const TextStyle(color: ZitlasColors.textMuted, fontSize: 12)),
          ],
          if (isNetworkImageUrl(cert.certificateUrl)) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                cert.certificateUrl!,
                height: 190,
                width: double.infinity,
                fit: BoxFit.cover,
                loadingBuilder: (ctx, child, progress) => progress == null
                    ? child
                    : Container(
                        height: 190,
                        alignment: Alignment.center,
                        color: ZitlasColors.bgCardLight,
                        child: const CircularProgressIndicator(color: ZitlasColors.primary),
                      ),
                errorBuilder: (ctx, _, _) => Container(
                  height: 190,
                  alignment: Alignment.center,
                  color: ZitlasColors.bgCardLight,
                  child: const Text('Preview unavailable',
                      style: TextStyle(color: ZitlasColors.textMuted, fontSize: 12)),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => _reject(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ZitlasColors.error,
                    side: const BorderSide(color: ZitlasColors.error),
                  ),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: busy ? null : () => _approve(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ZitlasColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: busy
                      ? const SizedBox(
                          height: 18, width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
