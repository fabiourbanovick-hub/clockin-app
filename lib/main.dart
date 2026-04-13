import 'dart:io';
import 'dart:math';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const ClockInPhotoApp());
}

class ClockInPhotoApp extends StatelessWidget {
  const ClockInPhotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'C3 Fotos Clock In',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF19306A)),
        useMaterial3: true,
      ),
      home: const BatchHomePage(),
    );
  }
}

enum PhotoStatus { pending, approved, warning, rejected }

class PhotoItem {
  final String name;
  final String path;
  final double score;
  final PhotoStatus status;
  final List<String> issues;
  final String? outputPath;

  const PhotoItem({
    required this.name,
    required this.path,
    this.score = 0,
    this.status = PhotoStatus.pending,
    this.issues = const [],
    this.outputPath,
  });

  PhotoItem copyWith({
    String? name,
    String? path,
    double? score,
    PhotoStatus? status,
    List<String>? issues,
    String? outputPath,
  }) {
    return PhotoItem(
      name: name ?? this.name,
      path: path ?? this.path,
      score: score ?? this.score,
      status: status ?? this.status,
      issues: issues ?? this.issues,
      outputPath: outputPath ?? this.outputPath,
    );
  }
}

class BatchHomePage extends StatefulWidget {
  const BatchHomePage({super.key});

  @override
  State<BatchHomePage> createState() => _BatchHomePageState();
}

class _BatchHomePageState extends State<BatchHomePage> {
  final ImagePicker _picker = ImagePicker();
  late final FaceDetector _faceDetector;

  List<PhotoItem> items = [];
  bool isProcessing = false;
  bool isExporting = false;
  double progress = 0;
  String? exportMessage;
  PhotoStatus? selectedFilter;

  @override
  void initState() {
    super.initState();
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableLandmarks: true,
        enableClassification: false,
      ),
    );
  }

  @override
  void dispose() {
    _faceDetector.close();
    super.dispose();
  }

  List<PhotoItem> get filteredItems {
    if (selectedFilter == null) return items;
    return items.where((e) => e.status == selectedFilter).toList();
  }

  int get approvedCount =>
      items.where((e) => e.status == PhotoStatus.approved).length;
  int get warningCount =>
      items.where((e) => e.status == PhotoStatus.warning).length;
  int get rejectedCount =>
      items.where((e) => e.status == PhotoStatus.rejected).length;
  int get pendingCount =>
      items.where((e) => e.status == PhotoStatus.pending).length;

  Future<void> importImages() async {
    final images = await _picker.pickMultiImage();
    if (images.isEmpty) return;

    setState(() {
      items = images
          .map(
            (e) => PhotoItem(
              name: e.name,
              path: e.path,
            ),
          )
          .toList();
      progress = 0;
      exportMessage = null;
    });
  }

  Future<void> processBatch() async {
    if (items.isEmpty || isProcessing) return;

    setState(() {
      isProcessing = true;
      progress = 0;
      exportMessage = null;
    });

    final total = items.length;
    final updatedItems = <PhotoItem>[];

    for (int i = 0; i < total; i++) {
      final updated = await _processSingle(items[i]);
      updatedItems.add(updated);

      setState(() {
        items = List<PhotoItem>.from(updatedItems)
          ..addAll(items.skip(i + 1));
        progress = (i + 1) / total;
      });
    }

    setState(() {
      isProcessing = false;
    });
  }

  Future<PhotoItem> _processSingle(PhotoItem item) async {
    final issues = <String>[];

    try {
      final file = File(item.path);
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        return item.copyWith(
          score: 0,
          status: PhotoStatus.rejected,
          issues: ['Arquivo de imagem inválido'],
        );
      }

      final inputImage = InputImage.fromFilePath(item.path);
      final faces = await _faceDetector.processImage(inputImage);

      if (faces.isEmpty) {
        return item.copyWith(
          score: 0,
          status: PhotoStatus.rejected,
          issues: ['Nenhum rosto detectado'],
        );
      }

      if (faces.length > 1) {
        return item.copyWith(
          score: 20,
          status: PhotoStatus.rejected,
          issues: ['Mais de um rosto detectado'],
        );
      }

      final face = faces.first;
      final imageWidth = decoded.width.toDouble();
      final imageHeight = decoded.height.toDouble();
      final faceBox = face.boundingBox;
      final faceArea = faceBox.width * faceBox.height;
      final imageArea = imageWidth * imageHeight;
      final faceRatio = imageArea > 0 ? faceArea / imageArea : 0;

      double score = 100;

      if (faceRatio < 0.08) {
        issues.add('Rosto muito distante');
        score -= 25;
      } else if (faceRatio < 0.12) {
        issues.add('Rosto pequeno na imagem');
        score -= 10;
      }

      final centerX = faceBox.left + (faceBox.width / 2);
      final centerY = faceBox.top + (faceBox.height / 2);
      final offsetX = (centerX - imageWidth / 2).abs() / imageWidth;
      final offsetY = (centerY - imageHeight / 2).abs() / imageHeight;

      if (offsetX > 0.18 || offsetY > 0.18) {
        issues.add('Rosto fora do centro');
        score -= 15;
      }

      final brightness = _calculateBrightness(decoded);
      if (brightness < 75) {
        issues.add('Imagem escura');
        score -= 15;
      } else if (brightness > 190) {
        issues.add('Imagem muito clara');
        score -= 15;
      }

      final sharpness = _calculateSharpness(decoded);
      if (sharpness < 12) {
        issues.add('Baixa nitidez');
        score -= 20;
      } else if (sharpness < 20) {
        issues.add('Nitidez abaixo do ideal');
        score -= 8;
      }

      final leftEye = face.landmarks[FaceLandmarkType.leftEye]?.position;
      final rightEye = face.landmarks[FaceLandmarkType.rightEye]?.position;

      if (leftEye == null || rightEye == null) {
        issues.add('Olhos não detectados com clareza');
        score -= 10;
      } else {
        final eyeAngle = atan2(
              rightEye.y - leftEye.y,
              rightEye.x - leftEye.x,
            ) *
            180 /
            pi;

        if (eyeAngle.abs() > 12) {
          issues.add('Cabeça inclinada');
          score -= 10;
        }
      }

      score = score.clamp(0, 100);
      final processed = _cropAndNormalize(decoded, faceBox);
      final outputPath = await _saveProcessedImage(item.name, processed);
      final status = _statusFromScore(score, issues);

      return item.copyWith(
        score: score,
        status: status,
        issues: issues,
        outputPath: outputPath,
      );
    } catch (_) {
      return item.copyWith(
        score: 0,
        status: PhotoStatus.rejected,
        issues: ['Erro ao processar imagem'],
      );
    }
  }

  PhotoStatus _statusFromScore(double score, List<String> issues) {
    final critical = issues.any(
      (e) =>
          e.contains('Nenhum rosto') ||
          e.contains('Mais de um rosto') ||
          e.contains('Baixa nitidez'),
    );

    if (critical || score < 70) return PhotoStatus.rejected;
    if (score < 85) return PhotoStatus.warning;
    return PhotoStatus.approved;
  }

  double _calculateBrightness(img.Image image) {
    double sum = 0;
    int total = 0;

    for (int y = 0; y < image.height; y += 4) {
      for (int x = 0; x < image.width; x += 4) {
        final pixel = image.getPixel(x, y);
        final r = pixel.r.toDouble();
        final g = pixel.g.toDouble();
        final b = pixel.b.toDouble();
        sum += (0.299 * r) + (0.587 * g) + (0.114 * b);
        total++;
      }
    }

    return total == 0 ? 0 : sum / total;
  }

  double _calculateSharpness(img.Image image) {
    final gray = img.grayscale(image);
    double sum = 0;
    double sumSq = 0;
    int count = 0;

    for (int y = 1; y < gray.height - 1; y += 2) {
      for (int x = 1; x < gray.width - 1; x += 2) {
        final c = gray.getPixel(x, y).r.toDouble();
        final up = gray.getPixel(x, y - 1).r.toDouble();
        final down = gray.getPixel(x, y + 1).r.toDouble();
        final left = gray.getPixel(x - 1, y).r.toDouble();
        final right = gray.getPixel(x + 1, y).r.toDouble();

        final lap = (4 * c) - up - down - left - right;
        sum += lap;
        sumSq += lap * lap;
        count++;
      }
    }

    if (count == 0) return 0;
    final mean = sum / count;
    return (sumSq / count) - (mean * mean);
  }

  img.Image _cropAndNormalize(img.Image source, Rect faceBox) {
    final faceCenterX = faceBox.left + faceBox.width / 2;
    final faceCenterY = faceBox.top + faceBox.height / 2;

    final cropWidth = min(source.width.toDouble(), faceBox.width * 2.2);
    final cropHeight = min(source.height.toDouble(), faceBox.height * 2.8);

    int x = max(0, (faceCenterX - cropWidth / 2).round());
    int y = max(0, (faceCenterY - cropHeight / 2).round());
    int width = min(source.width - x, cropWidth.round());
    int height = min(source.height - y, cropHeight.round());

    if (width <= 0 || height <= 0) {
      return img.copyResize(source, width: 720, height: 960);
    }

    var cropped = img.copyCrop(
      source,
      x: x,
      y: y,
      width: width,
      height: height,
    );

    cropped = img.adjustColor(cropped, brightness: 0.03, contrast: 1.05);
    return img.copyResize(cropped, width: 720, height: 960);
  }

  Future<String> _saveProcessedImage(String originalName, img.Image image) async {
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/clockin_processadas');

    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final safeName = originalName.toLowerCase().replaceAll(' ', '_');
    final outputFile = File('${outDir.path}/proc_$safeName');
    final jpg = img.encodeJpg(image, quality: 92);
    await outputFile.writeAsBytes(jpg, flush: true);
    return outputFile.path;
  }

  Future<void> exportBatchResults() async {
    if (items.isEmpty || isExporting) return;

    setState(() {
      isExporting = true;
      exportMessage = null;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final baseDir = Directory('${dir.path}/clockin_export');
      final approvedDir = Directory('${baseDir.path}/aprovadas');
      final warningDir = Directory('${baseDir.path}/ressalva');
      final rejectedDir = Directory('${baseDir.path}/reprovadas');

      await approvedDir.create(recursive: true);
      await warningDir.create(recursive: true);
      await rejectedDir.create(recursive: true);

      final csvData = <List<String>>[
        ['arquivo', 'score', 'status', 'motivos', 'saida']
      ];

      for (final item in items) {
        if (item.outputPath == null) {
          csvData.add([
            item.name,
            item.score.toStringAsFixed(0),
            item.status.name,
            item.issues.join(' | '),
            '',
          ]);
          continue;
        }

        final source = File(item.outputPath!);
        Directory targetDir;

        switch (item.status) {
          case PhotoStatus.approved:
            targetDir = approvedDir;
            break;
          case PhotoStatus.warning:
            targetDir = warningDir;
            break;
          case PhotoStatus.rejected:
          case PhotoStatus.pending:
            targetDir = rejectedDir;
            break;
        }

        final newPath = '${targetDir.path}/${item.name}';
        await source.copy(newPath);

        csvData.add([
          item.name,
          item.score.toStringAsFixed(0),
          item.status.name,
          item.issues.join(' | '),
          newPath,
        ]);
      }

      final csv = const ListToCsvConverter().convert(csvData);
      final csvFile = File('${baseDir.path}/resultado.csv');
      await csvFile.writeAsString(csv);

      setState(() {
        exportMessage = 'Exportado em: ${baseDir.path}';
      });
    } catch (_) {
      setState(() {
        exportMessage = 'Erro ao exportar o lote.';
      });
    } finally {
      setState(() {
        isExporting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('C3 Fotos Clock In'),
        centerTitle: true,
      ),
      body: Container(
        color: const Color(0xFFF7F8FC),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Padronização de fotos',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Importe imagens, processe o lote e exporte os resultados.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: isProcessing ? null : importImages,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('Selecionar fotos'),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed: isProcessing ? null : processBatch,
                              icon: const Icon(Icons.play_arrow_outlined),
                              label: const Text('Processar'),
                              style: FilledButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 18),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed:
                              isProcessing || isExporting ? null : exportBatchResults,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('Exportar resultado'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _StatusCard(
                        label: 'Aprovadas',
                        value: approvedCount,
                        color: Colors.green,
                        icon: Icons.check_circle_outline,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatusCard(
                        label: 'Ressalva',
                        value: warningCount,
                        color: Colors.orange,
                        icon: Icons.warning_amber_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _StatusCard(
                        label: 'Reprovadas',
                        value: rejectedCount,
                        color: Colors.red,
                        icon: Icons.cancel_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatusCard(
                        label: 'Pendentes',
                        value: pendingCount,
                        color: Colors.blueGrey,
                        icon: Icons.hourglass_empty,
                      ),
                    ),
                  ],
                ),
                if (exportMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(exportMessage!),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Todos'),
                      selected: selectedFilter == null,
                      onSelected: (_) => setState(() => selectedFilter = null),
                    ),
                    ChoiceChip(
                      label: const Text('Aprovadas'),
                      selected: selectedFilter == PhotoStatus.approved,
                      onSelected: (_) =>
                          setState(() => selectedFilter = PhotoStatus.approved),
                    ),
                    ChoiceChip(
                      label: const Text('Ressalva'),
                      selected: selectedFilter == PhotoStatus.warning,
                      onSelected: (_) =>
                          setState(() => selectedFilter = PhotoStatus.warning),
                    ),
                    ChoiceChip(
                      label: const Text('Reprovadas'),
                      selected: selectedFilter == PhotoStatus.rejected,
                      onSelected: (_) =>
                          setState(() => selectedFilter = PhotoStatus.rejected),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (isProcessing || progress > 0)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LinearProgressIndicator(
                        value: isProcessing ? progress : null,
                      ),
                      const SizedBox(height: 6),
                      Text('${(progress * 100).toStringAsFixed(0)}% concluído'),
                      const SizedBox(height: 12),
                    ],
                  ),
                Expanded(
                  child: filteredItems.isEmpty
                      ? const Center(
                          child: Text('Selecione fotos para começar.'),
                        )
                      : GridView.builder(
                          itemCount: filteredItems.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.9,
                          ),
                          itemBuilder: (context, index) {
                            final item = filteredItems[index];
                            return _PhotoCard(item: item);
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;

  const _StatusCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withAlpha(25),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              Text(label),
            ],
          ),
        ],
      ),
    );
  }
}

class _PhotoCard extends StatelessWidget {
  final PhotoItem item;

  const _PhotoCard({required this.item});

  Color get color {
    switch (item.status) {
      case PhotoStatus.pending:
        return Colors.blueGrey;
      case PhotoStatus.approved:
        return Colors.green;
      case PhotoStatus.warning:
        return Colors.orange;
      case PhotoStatus.rejected:
        return Colors.red;
    }
  }

  String get label {
    switch (item.status) {
      case PhotoStatus.pending:
        return 'Pendente';
      case PhotoStatus.approved:
        return 'Aprovada';
      case PhotoStatus.warning:
        return 'Com ressalva';
      case PhotoStatus.rejected:
        return 'Reprovada';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(item.path),
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey.shade200,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined, size: 42),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: color.withAlpha(30),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
            Text('Score: ${item.score.toStringAsFixed(0)}'),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: item.score <= 0 ? 0 : item.score / 100,
              minHeight: 8,
              borderRadius: BorderRadius.circular(99),
            ),
            const SizedBox(height: 8),
            Text(
              item.issues.isEmpty
                  ? 'Sem apontamentos'
                  : item.issues.join(' • '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
