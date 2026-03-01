import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/models/message_model.dart';
import '../../../core/l10n/app_localizations.dart';

class ContactPickerSheet extends StatefulWidget {
  const ContactPickerSheet({super.key});

  static Future<ContactData?> show(BuildContext context) {
    return showModalBottomSheet<ContactData>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => _ContactPickerContent(
          scrollController: scrollController,
        ),
      ),
    );
  }

  @override
  State<ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<ContactPickerSheet> {
  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

class _ContactPickerContent extends StatefulWidget {
  final ScrollController scrollController;

  const _ContactPickerContent({required this.scrollController});

  @override
  State<_ContactPickerContent> createState() => _ContactPickerContentState();
}

class _ContactPickerContentState extends State<_ContactPickerContent> {
  bool _isLoading = true;
  bool _hasPermission = false;
  List<_SimpleContact> _contacts = [];
  List<_SimpleContact> _filteredContacts = [];
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _hasPermission = true;
      _contacts = [];
      _filteredContacts = [];
      // Contacts feature disabled temporarily
    });
  }

  void _onSearch(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredContacts = List.from(_contacts);
      } else {
        final q = query.toLowerCase();
        _filteredContacts = _contacts
            .where((c) =>
                c.name.toLowerCase().contains(q) ||
                (c.phone?.contains(query) ?? false) ||
                (c.email?.toLowerCase().contains(q) ?? false))
            .toList();
      }
    });
  }

  void _selectContact(_SimpleContact contact) {
    Navigator.of(context).pop(ContactData(
      name: contact.name,
      email: contact.email,
      phone: contact.phone,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Share Contact',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.chatInputBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearch,
              style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context)?.t('search_chats') ?? 'Search contacts...',
                hintStyle: TextStyle(
                    color: AppColors.textDisabled.withValues(alpha: 0.6)),
                prefixIcon: const Icon(
                    Icons.search, color: AppColors.textDisabled, size: 20),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                      color: AppColors.primary, strokeWidth: 2.5),
                )
              : !_hasPermission
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.contacts_outlined,
                              color: AppColors.textDisabled, size: 48),
                          const SizedBox(height: 12),
                          const Text(
                            'Contact permission required',
                            style: TextStyle(
                                fontSize: 15, color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _loadContacts,
                            child: const Text('Grant Permission'),
                          ),
                        ],
                      ),
                    )
                  : _filteredContacts.isEmpty
                      ? const Center(
                          child: Text(
                            'Contacts not available',
                            style: TextStyle(
                                fontSize: 14, color: AppColors.textDisabled),
                          ),
                        )
                      : ListView.builder(
                          controller: widget.scrollController,
                          itemCount: _filteredContacts.length,
                          itemBuilder: (context, index) {
                            final contact = _filteredContacts[index];
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: AppColors.teal50,
                                child: Text(
                                  contact.name.isNotEmpty
                                      ? contact.name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                    color: AppColors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text(
                                contact.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              subtitle: Text(
                                contact.phone ?? contact.email ?? '',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textTertiary,
                                ),
                              ),
                              onTap: () => _selectContact(contact),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}

class _SimpleContact {
  final String name;
  final String? phone;
  final String? email;

  _SimpleContact({required this.name, this.phone, this.email});
}
