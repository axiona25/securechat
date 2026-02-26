import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/api_service.dart';

class DocumentViewerScreen extends StatefulWidget {
  final String fileUrl;
  final String fileName;
  final String mimeType;
  final String? attachmentId;

  const DocumentViewerScreen({
    super.key,
    required this.fileUrl,
    required this.fileName,
    this.mimeType = '',
    this.attachmentId,
  });

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  bool _loading = true;
  String? _localPath;
  String? _error;
  PdfControllerPinch? _pdfController;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    _loadDocument();
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
    super.dispose();
  }

  bool get _isOfficeFile {
    final ext = widget.fileName.toLowerCase();
    return ext.endsWith('.xlsx') || ext.endsWith('.xls') ||
        ext.endsWith('.docx') || ext.endsWith('.doc') ||
        ext.endsWith('.pptx') || ext.endsWith('.ppt');
  }

  Future<void> _loadDocument() async {
    try {
      debugPrint('📄 DocumentViewer: fileName=${widget.fileName}, isOffice=$_isOfficeFile, attachmentId=${widget.attachmentId}');
      debugPrint('📄 DocumentViewer: fileUrl=${widget.fileUrl}');
      setState(() {
        _loading = true;
        _error = null;
      });

      String? pdfPath;

      if (_isOfficeFile && widget.attachmentId != null && widget.attachmentId!.isNotEmpty) {
        pdfPath = await _downloadConvertedPdf();
      } else {
        pdfPath = await _downloadFile();
      }

      if (!mounted) return;
      _localPath = pdfPath;
      final isPdf = widget.fileName.toLowerCase().endsWith('.pdf') ||
          widget.mimeType == 'application/pdf';
      final isConvertedOffice = _isOfficeFile && widget.attachmentId != null && widget.attachmentId!.isNotEmpty;
      if (pdfPath != null && (isPdf || isConvertedOffice)) {
        _pdfController = PdfControllerPinch(
          document: PdfDocument.openFile(pdfPath),
        );
      }
      setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<String> _downloadConvertedPdf() async {
    final token = ApiService().accessToken;
    final baseUrl = AppConstants.baseUrl;
    final url = '$baseUrl/chat/convert/${widget.attachmentId}/';
    debugPrint('📄 Convert URL: $url');
    debugPrint('📄 Token present: ${token != null}');

    final response = await http.get(
      Uri.parse(url),
      headers: token != null ? {'Authorization': 'Bearer $token'} : {},
    );

    if (response.statusCode != 200) {
      throw Exception('Conversione fallita: ${response.statusCode}');
    }

    final dir = await getTemporaryDirectory();
    final safeName = widget.fileName.replaceAll(RegExp(r'[^\w\.\-]'), '_');
    final file = File('${dir.path}/${safeName}_converted.pdf');
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  Future<String?> _downloadFile() async {
    final token = ApiService().accessToken;
    String downloadUrl = widget.fileUrl;
    if (downloadUrl.contains('/api/chat/media/')) {
      downloadUrl = downloadUrl.replaceFirst('/api/chat/media/', '/media/');
    }

    var response = await http.get(
      Uri.parse(downloadUrl),
      headers: token != null ? {'Authorization': 'Bearer $token'} : {},
    );
    if (response.statusCode != 200) {
      response = await http.get(Uri.parse(downloadUrl));
    }
    if (response.statusCode != 200) {
      throw Exception('Download fallito: ${response.statusCode}');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${widget.fileName}');
    await file.writeAsBytes(response.bodyBytes);
    return file.path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF4A4A4A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A2B4A),
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          widget.fileName,
          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_localPath != null)
            IconButton(
              icon: const Icon(Icons.ios_share_rounded, color: Colors.white),
              onPressed: _shareFile,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF2ABFBF)),
            SizedBox(height: 16),
            Text('Scaricamento in corso...', style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Errore nel caricamento',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_isOfficeFile)
                ElevatedButton.icon(
                  onPressed: _openWithExternalApp,
                  icon: const Icon(Icons.open_in_new_rounded, size: 20),
                  label: const Text('Apri con altra app'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2ABFBF),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (_pdfController == null) {
      if (_localPath != null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.insert_drive_file_rounded, size: 64, color: Colors.white54),
              const SizedBox(height: 16),
              Text(
                widget.fileName,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _openWithExternalApp,
                icon: const Icon(Icons.open_in_new_rounded, size: 20),
                label: const Text('Apri con altra app'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2ABFBF),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return PdfViewPinch(
      controller: _pdfController!,
      padding: 8,
      backgroundDecoration: const BoxDecoration(color: Color(0xFF4A4A4A)),
      builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
        options: const DefaultBuilderOptions(),
        documentLoaderBuilder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF2ABFBF)),
        ),
        pageLoaderBuilder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF2ABFBF)),
        ),
        errorBuilder: (_, error) => Center(
          child: Text(
            error.toString(),
            style: const TextStyle(color: Colors.red),
          ),
        ),
      ),
    );
  }

  Future<void> _openWithExternalApp() async {
    if (_localPath != null) {
      try {
        final result = await OpenFilex.open(_localPath!);
        if (result.type != ResultType.done && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Impossibile aprire: ${result.message}'), backgroundColor: Colors.red),
          );
        }
      } catch (e) {
        debugPrint('Errore apertura file: $e');
      }
      return;
    }
    if (widget.fileUrl.isEmpty) return;
    try {
      final token = ApiService().accessToken;
      String url = widget.fileUrl;
      if (url.contains('/api/chat/media/')) url = url.replaceFirst('/api/chat/media/', '/media/');
      final response = await http.get(
        Uri.parse(url),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      );
      if (response.statusCode == 200) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/${widget.fileName}');
        await file.writeAsBytes(response.bodyBytes);
        final result = await OpenFilex.open(file.path);
        if (result.type != ResultType.done && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Impossibile aprire: ${result.message}'), backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      debugPrint('Errore download/apertura: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossibile aprire il file'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _shareFile() async {
    if (_localPath == null) return;
    try {
      await Share.shareXFiles([XFile(_localPath!)], subject: widget.fileName);
    } catch (e) {
      debugPrint('Errore condivisione: $e');
    }
  }
}
