import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

// ============================================================
//  Hitung lembaran (gypsum / triplek / GRC) dari foto TEPI tumpukan.
//
//  Prinsip: tiap lembar dipisahkan garis gelap tipis. Foto dibagi menjadi
//  beberapa jalur vertikal; di tiap jalur dicari kemiringan garis terbaik
//  (agar foto miring / perspektif tetap terbaca), dirata-ratakan menjadi
//  profil 1 dimensi, lalu lembah (garis gelap) dihitung.
//  Hasil akhir = jumlah lembar (garis penanda berada di tengah tiap lembar).
// ============================================================

/// Satu penanda lembar: garis dari (x0,y0) ke (x1,y1), koordinat piksel gambar.
class SheetLine {
  double x0, y0, x1, y1;
  bool auto;
  SheetLine(this.x0, this.y0, this.x1, this.y1, this.auto);

  double get slope => (x1 - x0).abs() < 1e-6 ? 0.0 : (y1 - y0) / (x1 - x0);
  double yAt(double x) => y0 + slope * (x - x0);
  double get ym => (y0 + y1) / 2;
}

Float32List _toF32(Uint8List px) {
  final f = Float32List(px.length);
  for (var i = 0; i < px.length; i++) {
    f[i] = px[i].toDouble();
  }
  return f;
}

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

Float64List _gauss1(Float64List p, double s) {
  final n = p.length;
  final r = (s * 3).ceil();
  final k = Float64List(2 * r + 1);
  var sum = 0.0;
  for (var i = -r; i <= r; i++) {
    final v = math.exp(-0.5 * (i / s) * (i / s));
    k[i + r] = v;
    sum += v;
  }
  for (var i = 0; i < k.length; i++) {
    k[i] /= sum;
  }
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    var acc = 0.0;
    for (var j = -r; j <= r; j++) {
      var q = i + j;
      if (q < 0) q = 0;
      if (q > n - 1) q = n - 1;
      acc += k[j + r] * p[q];
    }
    out[i] = acc;
  }
  return out;
}

class _Prof {
  final Float64List p;
  final List<bool> ok;
  final int off;
  _Prof(this.p, this.ok, this.off);
}

/// Profil 1D: rata-rata kecerahan sepanjang garis berkemiringan [slope] (px per px) di jalur [xa, xb).
_Prof _profile(Float32List g, int w, int h, int xa, int xb, double slope) {
  final sw = xb - xa;
  final off = (slope.abs() * sw / 2).ceil() + 1;
  final n = h + 2 * off;
  final sum = Float64List(n);
  final cnt = Int32List(n);
  final cx = sw / 2.0;
  for (var y = 0; y < h; y++) {
    final row = y * w + xa;
    for (var x = 0; x < sw; x += 2) {
      final i = (y - slope * (x - cx)).round() + off;
      sum[i] += g[row + x];
      cnt[i]++;
    }
  }
  final xn = (sw + 1) ~/ 2;
  final p = Float64List(n);
  final ok = List<bool>.filled(n, false);
  for (var i = 0; i < n; i++) {
    if (cnt[i] > 0) p[i] = sum[i] / cnt[i];
    ok[i] = cnt[i] >= 0.6 * xn;
  }
  return _Prof(p, ok, off);
}

double _sharp(_Prof pr) {
  var s = 0.0;
  var c = 0;
  for (var i = 1; i < pr.p.length; i++) {
    if (pr.ok[i] && pr.ok[i - 1]) {
      final d = pr.p[i] - pr.p[i - 1];
      s += d * d;
      c++;
    }
  }
  return c == 0 ? 0.0 : s / c;
}

/// Kemiringan garis lembar terbaik = yang membuat profil paling tajam.
double _bestSlope(Float32List g, int w, int h, int xa, int xb) {
  var best = -1.0, bs = 0.0;
  for (var k = -20; k <= 20; k++) {
    final s = k * 0.02;
    final e = _sharp(_profile(g, w, h, xa, xb, s));
    if (e > best) {
      best = e;
      bs = s;
    }
  }
  final c = bs;
  for (var j = 0; j <= 10; j++) {
    final s = c - 0.02 + j * 0.004;
    final e = _sharp(_profile(g, w, h, xa, xb, s));
    if (e > best) {
      best = e;
      bs = s;
    }
  }
  return bs;
}

class _Cand {
  final int i;
  final double prom;
  _Cand(this.i, this.prom);
}

/// Seberapa dalam lembah di indeks [i] dibanding sekitarnya.
double _prominence(Float64List s, int i, int lim) {
  final n = s.length;
  final v = s[i];
  var lm = v;
  var j = i - 1;
  while (j >= 0 && j >= i - lim && s[j] >= v) {
    if (s[j] > lm) lm = s[j];
    j--;
  }
  var rm = v;
  j = i + 1;
  while (j < n && j <= i + lim && s[j] >= v) {
    if (s[j] > rm) rm = s[j];
    j++;
  }
  return math.min(lm, rm) - v;
}

class _Strip {
  final double slope, period, score;
  final List<double> centers; // y tengah tiap lembar pada x tengah jalur (px working)
  _Strip(this.slope, this.centers, this.period, this.score);
}

_Strip? _analyzeStrip(Float32List g, int w, int h, int xa, int xb, double sens, double fillTol, {double? refY, double? fixedPitch}) {
  final sl = _bestSlope(g, w, h, xa, xb);
  final pr = _profile(g, w, h, xa, xb, sl);
  var a = 0;
  while (a < pr.p.length && !pr.ok[a]) {
    a++;
  }
  var b = pr.p.length - 1;
  while (b > a && !pr.ok[b]) {
    b--;
  }
  if (b - a < 40) return null;
  final P = Float64List.fromList(pr.p.sublist(a, b + 1));
  final S = _gauss1(P, 0.8);
  final G3 = _gauss1(S, 3.0);
  final hp = <double>[for (var i = 0; i < S.length; i++) S[i] - G3[i]];
  final hm = _median(hp);
  final mad = _median([for (final x in hp) (x - hm).abs()]) * 1.4826 + 1e-6;

  final cands = <_Cand>[];
  for (var i = 1; i < S.length - 1; i++) {
    if (S[i] < S[i - 1] && S[i] <= S[i + 1]) cands.add(_Cand(i, _prominence(S, i, 60)));
  }
  // ambang rendah: garis tipis antar-lembar yang samar ikut terhitung
  final thr = math.max(0.6, 1.0 * mad / sens);
  var v = <_Cand>[
    for (final c in cands)
      if (c.prom >= thr) c,
  ];
  if (v.length < 4) return null;
  // buang lembah terlalu rapat (iteratif terhadap median jarak; ambil yang lebih dalam)
  for (var it = 0; it < 3 && v.length >= 3; it++) {
    final med = _median([for (var k = 1; k < v.length; k++) (v[k].i - v[k - 1].i).toDouble()]);
    final out = <_Cand>[];
    for (final c in v) {
      if (out.isNotEmpty && c.i - out.last.i < 0.5 * med) {
        if (c.prom > out.last.prom) out[out.length - 1] = c;
      } else {
        out.add(c);
      }
    }
    v = out;
  }
  if (v.length < 4) return null;
  if (fixedPitch != null && fixedPitch > 2) {
    // tebal 1 lembar ditentukan user (tarik atas-bawah): buang lembah yang lebih rapat dari ~0.55 tebal
    final o2 = <_Cand>[];
    for (final c in v) {
      if (o2.isNotEmpty && c.i - o2.last.i < 0.55 * fixedPitch) {
        if (c.prom > o2.last.prom) o2[o2.length - 1] = c;
      } else {
        o2.add(c);
      }
    }
    v = o2;
    if (v.length < 4) return null;
  }
  final pos = <double>[for (final c in v) c.i.toDouble()];
  var pitch = _median([for (var k = 1; k < pos.length; k++) pos[k] - pos[k - 1]]);
  // metode manual: jarak antar-lembar diambil dari lembah terdekat dengan titik contoh (refY)
  if (refY != null) {
    final ri = refY.round() + pr.off - a;
    final near = <_Cand>[
      for (final c in cands)
        if (c.prom >= 1.5 * thr) c,
    ]..sort((p, q) => (p.i - ri).abs().compareTo((q.i - ri).abs()));
    if (near.length >= 4) {
      final idx = [for (final c in near.take(5)) c.i]..sort();
      final pm = _median([for (var k = 1; k < idx.length; k++) (idx[k] - idx[k - 1]).toDouble()]);
      if (pm >= 3) pitch = pm;
    }
  }
  if (fixedPitch != null && fixedPitch > 2) pitch = fixedPitch;
  if (pitch <= 1) return null;

  // buang lembah di ujung yang jaraknya tidak beraturan (palet / latar di luar tumpukan)
  bool reg(double x, double y) {
    final r = (y - x) / pitch;
    final n = r.round();
    return n >= 1 && n <= 3 && (r - n).abs() < 0.4;
  }

  while (pos.length > 4 && !reg(pos[0], pos[1])) {
    pos.removeAt(0);
  }
  while (pos.length > 4 && !reg(pos[pos.length - 2], pos[pos.length - 1])) {
    pos.removeLast();
  }

  // isi garis samar yang terlewat (celah ~ kelipatan jarak). fillTol 0 = tidak mengisi.
  final bnd = <double>[pos[0]];
  for (var k = 1; k < pos.length; k++) {
    final gap = pos[k] - pos[k - 1];
    final r = gap / pitch;
    final m = r.round();
    if (m >= 2 && (r - m).abs() < fillTol) {
      for (var j = 1; j < m; j++) {
        bnd.add(pos[k - 1] + gap * j / m);
      }
    }
    bnd.add(pos[k]);
  }
  // 1 garis = 1 lembar (lembar tepat di atas garis); penanda di tengah lembar itu
  final cen = <double>[for (var k = 0; k < bnd.length; k++) bnd[k] - (k == 0 ? pitch : bnd[k] - bnd[k - 1]) / 2];

  var sc = 0.0;
  for (final c in v) {
    sc += c.prom;
  }
  sc = sc / v.length / mad;
  return _Strip(sl, [for (final c in cen) c + a - pr.off], pitch, sc);
}

/// Hitung lembaran. args: bytes (JPEG/PNG), sens (0.5..3, makin besar makin sensitif),
/// fill = toleransi pengisian garis samar (gypsum 0.3; triplek/GRC 0 = tidak mengisi).
/// pitch = tebal 1 lembar (px gambar asli) hasil tarik atas-bawah (Tap-Match). bw = lebar jalur (0..1), nb = jumlah jalur otomatis.
/// mx,my = titik contoh manual (px gambar asli): jalur dipusatkan di mx dan jarak antar-lembar diambil dari lembah di sekitar my.
/// bx = pusat jalur hitung (0..1 dari lebar). <0 = otomatis: 5 jalur dihitung, jumlah yang dipakai = median-nya.
/// Hasil: {'lines': [[x0,y0,x1,y1],...] (px gambar asli, urut dari atas), 'counts': [jumlah tiap jalur], 'period': jarak antar-lembar (px asli), 'bx': pusat jalur terpakai}
Map<String, dynamic> countSheets(Map<String, dynamic> a) {
  final sens = (a['sens'] as double?) ?? 1.0;
  final fillTol = (a['fill'] as double?) ?? 0.0;
  final src = cv.imdecode(a['bytes'] as Uint8List, cv.IMREAD_GRAYSCALE);
  final fw = src.cols, fh = src.rows;
  final sc = math.min(1.0, 2600 / math.max(fw, fh));
  cv.Mat m = src;
  if (sc < 1.0) {
    m = cv.resize(src, ((fw * sc).round(), (fh * sc).round()), interpolation: cv.INTER_AREA);
    src.dispose();
  }
  final w = m.cols, h = m.rows;
  final g = _toF32(Uint8List.fromList(m.data));
  m.dispose();

  // Jalur hitung SEMPIT (12% lebar): garis lembar pada foto miring/perspektif menyebar, jadi jalur lebar mengaburkan garis.
  final bw = ((a['bw'] as double?) ?? 0.12).clamp(0.06, 0.4).toDouble();
  final nb = ((a['nb'] as int?) ?? 5).clamp(1, 9).toInt();
  final fpx = a['pitch'] as double?;
  final sw = math.min(w, math.max(48, (w * bw).round()));
  final mx = a['mx'] as double?, my = a['my'] as double?;
  final fixedBx = mx != null ? (mx / fw).clamp(0.05, 0.95).toDouble() : ((a['bx'] as double?) ?? -1.0);
  final centers = fixedBx >= 0 ? <double>[fixedBx] : <double>[for (var k = 0; k < nb; k++) nb == 1 ? 0.5 : 0.2 + 0.6 * k / (nb - 1)];
  final res = <_Strip>[], bxs = <double>[], xas = <int>[];
  for (final c in centers) {
    final xa = (c * w - sw / 2).round().clamp(0, w - sw).toInt();
    final r = _analyzeStrip(g, w, h, xa, xa + sw, sens, fillTol, refY: (mx != null && my != null) ? my * sc : null, fixedPitch: fpx != null ? fpx * sc : null);
    if (r != null) {
      res.add(r);
      bxs.add(c);
      xas.add(xa);
    }
  }
  if (res.isEmpty) return {'lines': <List<double>>[], 'counts': <int>[], 'period': 0.0, 'bx': fixedBx};

  final counts = [for (final r in res) r.centers.length];
  final sorted = [...counts]..sort();
  final target = sorted[(sorted.length - 1) ~/ 2]; // median (bawah)
  var pick = -1;
  for (var k = 0; k < res.length; k++) {
    if (counts[k] == target && (pick < 0 || res[k].score > res[pick].score)) pick = k;
  }
  final best = res[pick];
  final bxa = xas[pick], bxb = bxa + sw;
  final x0 = bxa + 0.06 * sw, x1 = math.min(w - 1.0, bxa + 2.4 * sw), xm = bxa + sw / 2;
  final lines = <List<double>>[
    for (final c in best.centers) [x0 / sc, (c + best.slope * (x0 - xm)) / sc, x1 / sc, (c + best.slope * (x1 - xm)) / sc],
  ];
  return {'lines': lines, 'counts': counts, 'period': best.period / sc, 'bx': bxs[pick]};
}
