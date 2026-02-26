import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/models/message_model.dart';
import '../../../core/services/api_service.dart';
import 'fullscreen_image_viewer.dart';

enum MediaTab { photos, files, links }

class MediaGalleryScreen extends StatefulWidget {
  final String conversationId;
  final String conversationName;

  const MediaGalleryScreen({
    super.key,
    required this.conversationId,
    required this.conversationName,
  });

  @override
  State<MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends State<MediaGalleryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ApiService _api = ApiService();
  bool _isLoading = true;

  List<AttachmentModel> _photos = [];
  List<AttachmentModel> _files = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadMedia();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadMedia() async {
    try {
      final data = await _api.get(
        '/chat/conversations/${widget.conversationId}/media/',
      );
      final results = data['results'] as List<dynamic>? ?? [];

      final allAttachments = results
          .map((json) =>
              AttachmentModel.fromJson(json as Map<String, dynamic>))
          .toList();

      if (mounted) {
        setState(() {
          _photos = allAttachments.where((a) => a.isImage).toList();
          _files = allAttachments.where((a) => !a.isImage).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.scaffold,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_rounded, color: AppColors.primary),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.conversationName,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const Text(
              'Media, Files & Links',
              style: TextStyle(fontSize: 12, color: AppColors.textTertiary),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: AppColors.textDisabled,
          indicatorColor: AppColors.primary,
          indicatorWeight: 2.5,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          tabs: [
            Tab(text: 'Photos (${_photos.length})'),
            Tab(text: 'Files (${_files.length})'),
            const Tab(text: 'Links'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                  color: AppColors.primary, strokeWidth: 2.5))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildPhotosGrid(),
                _buildFilesList(),
                _buildLinksPlaceholder(),
              ],
            ),
    );
  }

  Widget _buildPhotosGrid() {
    if (_photos.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined,
                color: AppColors.textDisabled, size: 48),
            SizedBox(height: 12),
            Text('No photos yet',
                style: TextStyle(color: AppColors.textDisabled)),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: _photos.length,
      itemBuilder: (context, index) {
        final photo = _photos[index];
        final url = photo.thumbnailUrl ?? photo.fileUrl ?? '';

        return GestureDetector(
          onTap: () {
            if (photo.fileUrl != null && photo.fileUrl!.isNotEmpty) {
              FullscreenImageViewer.show(context, photo.fileUrl!);
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: url.isNotEmpty
                ? Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: AppColors.bgIce,
                      child: const Icon(Icons.broken_image_outlined,
                          color: AppColors.textDisabled),
                    ),
                  )
                : Container(
                    color: AppColors.bgIce,
                    child: const Icon(Icons.image_outlined,
                        color: AppColors.textDisabled),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildFilesList() {
    if (_files.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_open_outlined,
                color: AppColors.textDisabled, size: 48),
            SizedBox(height: 12),
            Text('No files yet',
                style: TextStyle(color: AppColors.textDisabled)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _files.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final file = _files[index];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.teal50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              file.isPdf
                  ? Icons.picture_as_pdf_outlined
                  : Icons.insert_drive_file_outlined,
              color: file.isPdf ? AppColors.error : AppColors.textSecondary,
            ),
          ),
          title: Text(
            file.fileName ?? 'Unknown',
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            file.fileSizeFormatted,
            style: const TextStyle(fontSize: 12, color: AppColors.textDisabled),
          ),
          trailing: const Icon(Icons.download_outlined,
              color: AppColors.primary, size: 22),
        );
      },
    );
  }

  Widget _buildLinksPlaceholder() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.link_outlined, color: AppColors.textDisabled, size: 48),
          SizedBox(height: 12),
          Text('No links yet',
              style: TextStyle(color: AppColors.textDisabled)),
        ],
      ),
    );
  }
}
