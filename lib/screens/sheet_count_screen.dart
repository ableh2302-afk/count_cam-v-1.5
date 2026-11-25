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
  final double period, lineW, markScale;
  final bool showNum, zigzag;
  final Offset? sample;
  final TransformationController tc;
  SheetPainter(this.lines, this.color, this.period, this.tc, {this.lineW = 1.0, this.markScale = 1.0, this.showNum = true, this.zigzag = true, this.sample}) : super(repaint: tc);

  static final Map<String, TextPainter> _tp = {};

  static TextPainter _text(int n, double fs, Color c) {
    final key = '$n|${fs.round()}|${c.toARGB32()}';
    if (_tp.length > 600) _tp.clear();
    return _tp[key] ??= TextPainter(
      text: TextSpan(text: '$n', style: TextStyle(color: c, fontSize: fs, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  /// Penanda gaya O----------- : lingkaran bernomor + garis ke kanan. Nomor ganjil digeser ke kanan (zigzag) agar lingkaran tidak berimpitan.
  /// [sc] = skala layar (px layar per px gambar).
  static void draw(Canvas c, List<SheetLine> ls, Color color, double sc, double period, {bool force = false, double lineW = 1.0, double markScale = 1.0, bool showNum = true, bool zigzag = true}) {
    final u = 1 / sc;
    final lw = math.max(1.0, 1.4 * u) * lineW;
    final line = Paint()
      ..strokeWidth = lw
      ..strokeCap = StrokeCap.round;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = lw;
    final r = math.max(period * 0.42 * markScale, 3 * u);
    final fs = r * 1.15;
    for (var i = 0; i < ls.length; i++) {
      final l = ls[i];
      final col = l.auto ? color : const Color(0xFFFFB300);
      final cx = l.x0 + r + (zigzag && i.isOdd ? 2.4 * r : 0);
      final cy = l.yAt(cx);
      final ex = math.max(l.x1, cx + r * 3);
      line.color = col.withValues(alpha: 0.9);
      c.drawLine(Offset(cx + r, l.yAt(cx + r)), Offset(ex, l.yAt(ex)), line);
      ring.color = col;
      c.drawCircle(Offset(cx, cy), r, ring);
      if (showNum && (force || r * sc >= 6)) {
        final tp = _text(i + 1, fs, col);
        tp.paint(c, Offset(cx - tp.width / 2, cy - tp.height / 2));
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sc = math.max(1e-6, tc.value.entry(0, 0).abs());
    final per = period > 1 ? period : 12.0;
    draw(canvas, lines, color, sc, per, lineW: lineW, markScale: markScale, showNum: showNum, zigzag: zigzag);
    final sp = sample;
    if (sp != null) {
      final u = 1 / sc;
      final paint = Paint()
        ..color = const Color(0xFFFFB300)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, 2 * u);
      final r = math.max(10 * u, 6.0);
      canvas.drawCircle(sp, r, paint);
      canvas.drawLine(Offset(sp.dx + r, sp.dy), Offset(sp.dx + r * 6, sp.dy), paint);
    }
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
  bool _fitted = false, busy = false, addMode = true, scanned = false;
  int method = 0; // 0 = Otomatis, 1 = Manual (tap contoh), 2 = Tap-Match (tap + tarik atas/bawah = tebal 1 lembar)
  bool get manual => method != 0;
  bool get tapMatch => method == 2;
  Offset? sample;
  double yTop = 0, yBot = 0; // batas atas/bawah 1 lembar (Tap-Match), px gambar asli
  List<SheetLine> lines = [];
  List<SheetLine>? _undo;
  List<int> stripCounts = [];
  double period = 0, bx = -1, bxUser = -1; // bxUser: jalur yang digeser user (<0 = otomatis, median 5 jalur)
  double sens = appSettings.sheetSens;
  late int thickIdx = widget.thickIdx;
  final rackCtl = TextEditingController();
  final noteCtl = TextEditingController();

  int get _tplIdx => math.max(0, kSheetTemplates.indexWhere((t) => t.id == widget.tpl.id));
  Color get _color => Color(appSettings.sheetColors[_tplIdx]);
  double get _fill => tapMatch ? 0.3 : ((widget.tpl.id == 'gypsum' ? appSettings.sheetFillG : appSettings.sheetFillO) ? 0.3 : 0.0);

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
      final r = await compute(countSheets, <String, dynamic>{'bytes': _bytes, 'sens': sens, 'fill': _fill, 'bx': bxUser, 'nb': appSettings.sheetBands, 'bw': appSettings.sheetBw / 100, 'pitch': (tapMatch && sample != null) ? (yBot - yTop) : null, 'mx': (manual && sample != null) ? sample!.dx : null, 'my': (manual && sample != null) ? sample!.dy : null});
      if (!mounted) return;
      final raw = (r['lines'] as List).map((e) => (e as List).cast<double>()).toList();
      setState(() {
        _undo = null;
        lines = [for (final l in raw) SheetLine(l[0], l[1], l[2], l[3], true)];
        stripCounts = (r['counts'] as List).cast<int>();
        period = (r['period'] as num).toDouble();
        bx = (r['bx'] as num).toDouble();
        scanned = manual;
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

  /// Mode Tambah: tap menambah penanda (mengikuti kemiringan garis terdekat). Mode Hapus: tap menghapus penanda terdekat.
  void _onTap(Offset pt) {
    if (busy || _img == null) return;
    if (manual && !scanned) {
      setState(() {
        sample = pt; // tap 1 lembar sebagai contoh
        if (tapMatch) {
          final p0 = period > 1 ? period : math.max(8.0, _img!.height / 60);
          yTop = pt.dy - p0 / 2;
          yBot = pt.dy + p0 / 2;
        }
      });
      _haptic();
      return;
    }
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
    final backup = [for (final l in lines) SheetLine(l.x0, l.y0, l.x1, l.y1, l.auto)];
    if (!addMode) {
      if (near == null || nd > 0.7 * per) return _snack('Tidak ada penanda di titik itu.');
      setState(() {
        _undo = backup;
        lines.remove(near);
      });
    } else {
      if (near != null && nd < 0.35 * per) return _snack('Sudah ada penanda di sini.');
      setState(() {
        _undo = backup;
        if (near != null) {
          final dy = pt.dy - near.yAt(pt.dx);
          lines.add(SheetLine(near.x0, near.y0 + dy, near.x1, near.y1 + dy, false));
        } else {
          final w = _img!.width.toDouble();
          lines.add(SheetLine(w * 0.06, pt.dy, w * 0.94, pt.dy, false));
        }
        _sortLines();
      });
    }
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

  /// Geser jalur hitung ke kiri/kanan (pilih bagian foto dengan garis lembar paling jelas) lalu hitung ulang.
  void _shiftBand(double d) {
    if (busy) return;
    bxUser = ((bxUser >= 0 ? bxUser : (bx >= 0 ? bx : 0.5)) + d).clamp(0.08, 0.92).toDouble();
    _detect();
  }

  Future<void> _rotate() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      _bytes = await compute(rotateImage, _bytes);
      bx = -1;
      bxUser = -1;
      sample = null;
      scanned = false;
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
    SheetPainter.draw(c, lines, _color, 800 / math.max(w, h), per, force: true, lineW: appSettings.sheetLineW, markScale: appSettings.sheetMark, showNum: appSettings.sheetNum, zigzag: appSettings.sheetZig);
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
                Positioned.fill(child: CustomPaint(painter: SheetPainter(lines, _color, period, tc, lineW: appSettings.sheetLineW, markScale: appSettings.sheetMark, showNum: appSettings.sheetNum, zigzag: appSettings.sheetZig, sample: tapMatch ? null : sample))),
                if (tapMatch && !scanned && sample != null) Positioned.fill(child: AnimatedBuilder(animation: tc, builder: (_, __) => _tapMatchOverlay())),
              ]),
            ),
          ),
        ),
      );
    });
  }

  /// Tap-Match: dua garis (atas & bawah) yang ditarik agar pas dengan tebal 1 lembar.
  Widget _tapMatchOverlay() {
    final sc = math.max(1e-6, tc.value.entry(0, 0).abs());
    final sp = sample!;
    final hw = 110 / sc, hh = 48 / sc;
    Widget handle(bool top) {
      final y = top ? yTop : yBot;
      return Positioned(
        left: sp.dx - hw,
        top: y - hh / 2,
        width: hw * 2,
        height: hh,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => setState(() {
            if (top) {
              yTop = math.min(yBot - 3, yTop + d.delta.dy);
            } else {
              yBot = math.max(yTop + 3, yBot + d.delta.dy);
            }
          }),
          child: CustomPaint(painter: _HandlePainter(sc)),
        ),
      );
    }

    return Stack(clipBehavior: Clip.none, children: [
      Positioned(left: sp.dx - hw, top: yTop, width: hw * 2, height: math.max(0.0, yBot - yTop), child: IgnorePointer(child: ColoredBox(color: const Color(0xFFFFB300).withValues(alpha: 0.22)))),
      handle(true),
      handle(false),
    ]);
  }

  Widget _modeBtn(IconData icon, String label, bool on, VoidCallback f) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: f,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: on ? cs.primaryContainer : cs.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: on ? cs.primary : cs.outlineVariant)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.onSurface)),
            Icon(icon, size: 30, color: on ? cs.primary : cs.outline),
          ]),
        ),
      ),
    );
  }

  Widget _panel() {
    final cs = Theme.of(context).colorScheme;
    final tpl = widget.tpl;
    final maxH = MediaQuery.of(context).size.height * 0.55;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: 0.5), border: Border(top: BorderSide(color: cs.outlineVariant))),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: 0, label: Text('Otomatis')), ButtonSegment(value: 1, label: Text('Manual')), ButtonSegment(value: 2, label: Text('Tap-Match'))],
              selected: {method},
              onSelectionChanged: busy
                  ? null
                  : (v) {
                      setState(() {
                        method = v.first;
                        scanned = false;
                        sample = null;
                        _undo = null;
                        if (method != 0) lines = [];
                      });
                      if (method == 0) {
                        bx = -1;
                        bxUser = -1;
                        _detect();
                      }
                    },
            ),
            const SizedBox(height: 6),
            if (manual && !scanned) ...[
              Text(tapMatch ? (sample == null ? 'Tap 1 lembar pada foto, lalu TARIK garis kuning atas & bawah agar pas dengan tebal 1 lembar. Tekan SCAN.' : 'Tarik garis kuning atas & bawah sampai pas 1 lembar (tap lagi untuk pindah), lalu SCAN.') : (sample == null ? 'Tap 1 garis / lembar pada foto sebagai CONTOH, lalu tekan SCAN.' : 'Contoh dipilih (tanda kuning). Tap lagi untuk memindahkan, atau tekan SCAN.'), textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: cs.outline)),
              const SizedBox(height: 6),
              SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: busy || sample == null ? null : _detect, icon: const Icon(Icons.search_rounded), label: const Text('SCAN'))),
            ] else ...[
              Text(manual ? 'Koreksi Penanda' : 'Koreksi Penanda  •  ◀ ▶ = geser jalur hitung', style: TextStyle(fontSize: 12.5, color: cs.outline)),
              const SizedBox(height: 4),
              Row(children: [
                const Spacer(),
                _modeBtn(Icons.add_rounded, 'Tambah', addMode, () => setState(() => addMode = true)),
                const SizedBox(width: 12),
                _modeBtn(Icons.remove_rounded, 'Hapus', !addMode, () => setState(() => addMode = false)),
                const Spacer(),
              ]),
              if (manual) TextButton.icon(onPressed: busy ? null : () => setState(() {
                    scanned = false;
                    sample = null;
                    lines = [];
                    _undo = null;
                  }), icon: const Icon(Icons.restart_alt_rounded, size: 18), label: const Text('Ulangi contoh')),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text('Pengaturan hitung & catatan', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5, color: cs.primary)),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 6, children: [
                    for (var i = 0; i < tpl.thicknesses.length; i++)
                      ChoiceChip(label: Text(SheetTemplate.mm(tpl.thicknesses[i])), selected: thickIdx == i, visualDensity: VisualDensity.compact, onSelected: (_) => setState(() => thickIdx = i)),
                  ]),
                ),
                Row(children: [
                  const Text('Ketebalan garis', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: appSettings.sheetLineW.clamp(0.5, 4.0).toDouble(),
                      min: 0.5,
                      max: 4.0,
                      divisions: 14,
                      label: appSettings.sheetLineW.toStringAsFixed(1),
                      onChanged: (v) => setState(() => appSettings.sheetLineW = v),
                      onChangeEnd: (_) => appSettings.save(),
                    ),
                  ),
                ]),
                Row(children: [
                  const Text('Sensitivitas', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  Expanded(
                    child: Slider(value: sens.clamp(0.5, 3.0).toDouble(), min: 0.5, max: 3.0, divisions: 25, label: sens.toStringAsFixed(1), onChanged: busy ? null : (v) => setState(() => sens = v)),
                  ),
                  IconButton.filledTonal(tooltip: 'Hitung ulang', onPressed: busy ? null : _detect, icon: const Icon(Icons.refresh_rounded)),
                ]),
                Row(children: [
                  Expanded(child: TextField(controller: rackCtl, decoration: const InputDecoration(labelText: 'Posisi rak / lokasi', isDense: true))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: noteCtl, decoration: const InputDecoration(labelText: 'Catatan', isDense: true))),
                ]),
                const SizedBox(height: 8),
              ],
            ),
            Row(children: [
              IconButton.outlined(tooltip: 'Putar 90°', onPressed: busy ? null : _rotate, icon: const Icon(Icons.rotate_90_degrees_cw_outlined)),
              const SizedBox(width: 8),
              IconButton.outlined(tooltip: 'Urungkan', onPressed: busy || _undo == null ? null : _undoTap, icon: const Icon(Icons.undo_rounded)),
              const SizedBox(width: 8),
              IconButton.outlined(tooltip: 'Geser jalur hitung ke kiri', onPressed: busy ? null : () => _shiftBand(-0.1), icon: const Icon(Icons.keyboard_arrow_left_rounded)),
              IconButton.outlined(tooltip: 'Geser jalur hitung ke kanan', onPressed: busy ? null : () => _shiftBand(0.1), icon: const Icon(Icons.keyboard_arrow_right_rounded)),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: busy ? null : _save, style: FilledButton.styleFrom(minimumSize: const Size(48, 54), shape: const StadiumBorder()), child: const Text('SIMPAN', style: TextStyle(fontSize: 17, letterSpacing: 1)))),
            ]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tpl = widget.tpl;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Hitung ${tpl.name}'),
        actions: [IconButton(tooltip: 'Pas ke layar', icon: const Icon(Icons.fit_screen_rounded), onPressed: _fitView)],
      ),
      body: Column(children: [
        Container(
          width: double.infinity,
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Hasil:', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
              decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(22)),
              child: Text('${lines.length}', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _color)),
            ),
          ]),
        ),
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

/// Garis penarik batas lembar (Tap-Match): garis horizontal + kenop di ujung kanan.
class _HandlePainter extends CustomPainter {
  final double sc;
  _HandlePainter(this.sc);
  @override
  void paint(Canvas c, Size z) {
    final u = 1 / sc;
    final p = Paint()
      ..color = const Color(0xFFFFB300)
      ..strokeWidth = math.max(1.5, 2.2 * u);
    c.drawLine(Offset(0, z.height / 2), Offset(z.width, z.height / 2), p);
    c.drawCircle(Offset(z.width - 12 * u, z.height / 2), 9 * u, p..style = PaintingStyle.fill);
    c.drawCircle(Offset(z.width - 12 * u, z.height / 2), 3.5 * u, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _HandlePainter old) => old.sc != sc;
}
