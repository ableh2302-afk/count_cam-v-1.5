import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models.dart';
import '../services/db.dart';
import '../services/detector.dart' show rotateImage;
import '../services/sheet_detector.dart';
import '../settings.dart';

/// Menggambar garis penanda lembar. Dipakai di layar (ikut zoom) dan saat membuat foto bertanda.
class SheetPainter extends CustomPainter {
  final List<SheetLine> lines;
  final Color color;
  final double period;
  final TransformationController tc;
  SheetPainter(this.lines, this.color, this.period, this.tc) : super(repaint: tc);

  static final Map<String, TextPainter> _tp = {};

  static TextPainter _text(int n, double fs, Color c) {
    final key = '$n|${fs.round()}|${c.toARGB32()}';
    if (_tp.length > 600) _tp.clear();
    return _tp[key] ??= TextPainter(
      text: TextSpan(text: '$n', style: TextStyle(color: Colors.white, fontSize: fs, fontWeight: FontWeight.w800, backgroundColor: c.withValues(alpha: 0.85))),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// [stroke] dan [fs] dalam piksel gambar. fs <= 0 = tanpa nomor.
  static void draw(Canvas c, List<SheetLine> ls, Color color, double stroke, double fs) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < ls.length; i++) {
      final l = ls[i];
      paint.color = l.auto ? color : const Color(0xFFFFB300);
      c.drawLine(Offset(l.x0, l.y0), Offset(l.x1, l.y1), paint);
      if (fs > 0) {
        final tp = _text(i + 1, fs, paint.color);
        tp.paint(c, Offset(l.x0 - tp.width - stroke, l.y0 - tp.height / 2));
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sc = math.max(1e-6, tc.value.entry(0, 0).abs());
    final fs = math.min(13 / sc, period * 0.8);
    draw(canvas, lines, color, math.max(1.0, 2.2 / sc), fs * sc >= 8 ? fs : 0);
  }

  @override
  bool shouldRepaint(covariant SheetPainter old) => true;
}

class SheetCountScreen extends StatefulWidget {
  final Uint8List bytes;
  final SheetTemplate tpl;
  final int thickIdx;
  const SheetCountScreen({super.key, required this.bytes, required this.tpl, required this.thickIdx});
  @override
  State<SheetCountScreen> createState() => _SheetCountScreenState();
}

class _SheetCountScreenState extends State<SheetCountScreen> {
  late Uint8List _bytes = widget.bytes;
  ui.Image? _img;
  final tc = TransformationController();
  Size _viewSize = Size.zero;
  bool _fitted = false, busy = false;
  List<SheetLine> lines = [];
  List<SheetLine>? _undo;
  List<int> stripCounts = [];
  double period = 0;
  late double sens = widget.tpl.sens;
  late int thickIdx = widget.thickIdx;
  final rackCtl = TextEditingController();
  final noteCtl = TextEditingController();

  Color get _color => Color(widget.tpl.color);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    tc.dispose();
    rackCtl.dispose();
    noteCtl.dispose();
    super.dispose();
  }

  void _snack(String m) {
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _load() async {
    final c = await ui.instantiateImageCodec(_bytes);
    final f = await c.getNextFrame();
    if (!mounted) return;
    setState(() {
      _img = f.image;
      _fitted = false;
    });
    await _detect();
  }

  Future<void> _detect() async {
    setState(() => busy = true);
    try {
      final r = await compute(countSheets, <String, dynamic>{'bytes': _bytes, 'sens': sens});
      if (!mounted) return;
      final raw = (r['lines'] as List).map((e) => (e as List).cast<double>()).toList();
      setState(() {
        _undo = null;
        lines = [for (final l in raw) SheetLine(l[0], l[1], l[2], l[3], true)];
        stripCounts = (r['counts'] as List).cast<int>();
        period = (r['period'] as num).toDouble();
        busy = false;
      });
      if (lines.isEmpty) _snack('Garis antar-lembar tidak terdeteksi. Coba crop lebih pas ke tepi tumpukan, atau naikkan sensitivitas.');
    } catch (e) {
      if (!mounted) return;
      setState(() => busy = false);
      _snack('Gagal menghitung: $e');
    }
  }

  void _fitView() {
    final img = _img;
    if (img == null || _viewSize == Size.zero) return;
    final w = img.width.toDouble(), h = img.height.toDouble();
    final k = math.min(_viewSize.width / w, _viewSize.height / h) * 0.98;
    tc.value = Matrix4(k, 0, 0, 0, 0, k, 0, 0, 0, 0, 1, 0, (_viewSize.width - w * k) / 2, (_viewSize.height - h * k) / 2, 0, 1);
  }

  void _haptic() {
    if (appSettings.haptic) HapticFeedback.lightImpact();
  }

  void _sortLines() => lines.sort((a, b) => a.ym.compareTo(b.ym));

  /// Tap dekat garis = hapus; tap di area kosong = tambah garis (mengikuti kemiringan garis terdekat).
  void _onTap(Offset pt) {
    if (busy || _img == null) return;
    _undo = [for (final l in lines) SheetLine(l.x0, l.y0, l.x1, l.y1, l.auto)];
    final per = period > 1 ? period : math.max(8.0, _img!.height / 60);
    SheetLine? near;
    var nd = double.infinity;
    for (final l in lines) {
      final d = (l.yAt(pt.dx) - pt.dy).abs();
      if (d < nd) {
        nd = d;
        near = l;
      }
    }
    setState(() {
      if (near != null && nd < 0.4 * per) {
        lines.remove(near);
      } else if (near != null) {
        final dy = pt.dy - near.yAt(pt.dx);
        lines.add(SheetLine(near.x0, near.y0 + dy, near.x1, near.y1 + dy, false));
      } else {
        final w = _img!.width.toDouble();
        lines.add(SheetLine(w * 0.06, pt.dy, w * 0.94, pt.dy, false));
      }
      _sortLines();
    });
    _haptic();
  }

  void _undoTap() {
    final u = _undo;
    if (u == null) return;
    setState(() {
      lines = u;
      _undo = null;
    });
  }

  Future<void> _rotate() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      _bytes = await compute(rotateImage, _bytes);
      await _load();
    } catch (e) {
      if (mounted) setState(() => busy = false);
      _snack('Gagal memutar: $e');
    }
  }

  // ---------- Simpan ----------
  Future<Uint8List> _render(DateTime now) async {
    final w = _img!.width.toDouble(), h = _img!.height.toDouble();
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawImage(_img!, Offset.zero, Paint());
    final u = math.max(w, h) / 800;
    final per = period > 1 ? period : h / math.max(1, lines.length);
    SheetPainter.draw(c, lines, _color, math.max(1.5, 1.6 * u), math.max(8.0, math.min(per * 0.6, 40 * u)));
    // keterangan di pojok kiri bawah
    final txt = '${widget.tpl.label(thickIdx)}\n${DateFormat('dd/MM/yyyy HH:mm').format(now)}\nTOTAL: ${lines.length} lembar';
    final tp = TextPainter(text: TextSpan(text: txt, style: TextStyle(color: Colors.white, fontSize: 14 * u, fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr)..layout();
    final pad = 8 * u;
    final r = Rect.fromLTWH(pad, h - tp.height - pad * 3, tp.width + pad * 2, tp.height + pad * 2);
    c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(pad)), Paint()..color = Colors.black.withValues(alpha: 0.65));
    tp.paint(c, Offset(r.left + pad, r.top + pad));
    final out = await rec.endRecording().toImage(w.toInt(), h.toInt());
    return (await out.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  }

  Future<void> _save() async {
    if (lines.isEmpty) return _snack('Belum ada hasil hitungan untuk disimpan.');
    setState(() => busy = true);
    try {
      final now = DateTime.now();
      final ts = DateFormat('yyyyMMdd_HHmmss').format(now);
      final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'camcount'))..createSync(recursive: true);
      final isPng = _bytes.length > 4 && _bytes[0] == 0x89 && _bytes[1] == 0x50;
      final orig = File(p.join(dir.path, 'asli_$ts.${isPng ? 'png' : 'jpg'}'))..writeAsBytesSync(_bytes);
      final ann = File(p.join(dir.path, 'bertanda_$ts.png'))..writeAsBytesSync(await _render(now));
      try {
        await Gal.putImage(ann.path);
      } catch (_) {}
      final manualAdd = lines.where((l) => !l.auto).length;
      await Db.insertSession({
        'tanggal_jam': DateFormat('yyyy-MM-dd HH:mm:ss').format(now),
        'posisi_rak': rackCtl.text.trim().isEmpty ? '-' : rackCtl.text.trim(),
        'mode_hitung': 'Lembar ${widget.tpl.name}',
        'total_semua_pipa': lines.length,
        'path_foto_asli': orig.path,
        'path_foto_bertanda': ann.path,
        'catatan': noteCtl.text.trim(),
      }, [
        {'ukuran_pipa': widget.tpl.label(thickIdx), 'jumlah_batang': lines.length, 'detail_rumus': manualAdd > 0 ? '$manualAdd lembar ditambah manual' : null},
      ]);
      if (!mounted) return;
      _snack('Tersimpan: ${lines.length} lembar');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => busy = false);
      _snack('Gagal menyimpan: $e');
    }
  }

  // ---------- UI ----------
  Widget _canvas() {
    final img = _img!;
    final w = img.width.toDouble(), h = img.height.toDouble();
    return LayoutBuilder(builder: (ctx, box) {
      _viewSize = Size(box.maxWidth, box.maxHeight);
      if (!_fitted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _fitted) return;
          _fitView();
          _fitted = true;
          setState(() {});
        });
      }
      return ClipRect(
        child: InteractiveViewer(
          transformationController: tc,
          constrained: false,
          minScale: 0.05,
          maxScale: 30,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          child: SizedBox(
            width: w,
            height: h,
            child: GestureDetector(
              onTapUp: (d) => _onTap(d.localPosition),
              child: Stack(children: [
                RawImage(image: img, width: w, height: h, fit: BoxFit.fill, filterQuality: FilterQuality.low),
                Positioned.fill(child: CustomPaint(painter: SheetPainter(lines, _color, period, tc))),
              ]),
            ),
          ),
        ),
      );
    });
  }

  Widget _panel() {
    final cs = Theme.of(context).colorScheme;
    final tpl = widget.tpl;
    return Container(
      decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${lines.length}', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: _color, height: 1)),
              const SizedBox(width: 6),
              const Padding(padding: EdgeInsets.only(bottom: 5), child: Text('lembar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              const Spacer(),
              if (stripCounts.length > 1) Text('Jalur: ${stripCounts.join(' · ')}', style: TextStyle(fontSize: 12, color: cs.outline)),
            ]),
            const SizedBox(height: 4),
            Text('Tap garis = hapus • Tap area kosong = tambah (kuning = manual). Cubit untuk zoom.', style: TextStyle(fontSize: 11.5, color: cs.outline)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 0, children: [
              for (var i = 0; i < tpl.thicknesses.length; i++)
                ChoiceChip(
                  label: Text(SheetTemplate.mm(tpl.thicknesses[i])),
                  selected: thickIdx == i,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => thickIdx = i),
                ),
            ]),
            Row(children: [
              const Text('Sensitivitas', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              Expanded(
                child: Slider(
                  value: sens.clamp(0.5, 3.0).toDouble(),
                  min: 0.5,
                  max: 3.0,
                  divisions: 25,
                  label: sens.toStringAsFixed(1),
                  onChanged: busy ? null : (v) => setState(() => sens = v),
                ),
              ),
              IconButton.filledTonal(tooltip: 'Hitung ulang', onPressed: busy ? null : _detect, icon: const Icon(Icons.refresh_rounded)),
            ]),
            Row(children: [
              Expanded(child: TextField(controller: rackCtl, decoration: const InputDecoration(labelText: 'Posisi rak / lokasi', isDense: true))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: noteCtl, decoration: const InputDecoration(labelText: 'Catatan', isDense: true))),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              OutlinedButton.icon(onPressed: busy ? null : _rotate, icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 18), label: const Text('Putar')),
              const SizedBox(width: 8),
              OutlinedButton.icon(onPressed: busy || _undo == null ? null : _undoTap, icon: const Icon(Icons.undo_rounded, size: 18), label: const Text('Urungkan')),
              const SizedBox(width: 8),
              Expanded(child: FilledButton.icon(onPressed: busy ? null : _save, icon: const Icon(Icons.save_rounded), label: const Text('Simpan'))),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tpl = widget.tpl;
    return Scaffold(
      appBar: AppBar(
        title: Text('Hitung ${tpl.name}'),
        actions: [IconButton(tooltip: 'Pas ke layar', icon: const Icon(Icons.fit_screen_rounded), onPressed: _fitView)],
      ),
      body: Column(children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: Container(color: Colors.black, child: _img == null ? null : _canvas())),
            if (busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black38,
                  alignment: Alignment.center,
                  child: const Column(mainAxisSize: MainAxisSize.min, children: [CircularProgressIndicator(), SizedBox(height: 10), Text('Menghitung lembar…', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))]),
                ),
              ),
          ]),
        ),
        _panel(),
      ]),
    );
  }
}
