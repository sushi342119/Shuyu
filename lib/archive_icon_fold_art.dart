part of 'archive_icons.dart';

/// Folded corners, typeset ink and a little asymmetry. Motion belongs to the
/// illustrated object: leaves fan, tabs lift, ribbons flex, ink marks settle.
_Art _foldDrawing(_IconPose pose, ArchiveIconGesture gesture) {
  final a = _Art();
  final p = gesture.lead, q = gesture.follow, r = gesture.trail;
  final active = pose.active.clamp(0.0, 1.0), v = pose.variant;
  switch (pose.symbol) {
    case ArchiveSymbol.discover:
      a.circle(12, 12, 8.6, fill: true, opacity: .07 + active * .11);
      a.circle(12, 12, 8.6);
      a.rotate(p * .55, () {
        a.poly([15.8, 8.2, 13.5, 13.5, 8.2, 15.8, 10.5, 10.5], close: true);
        a.poly(
          [15.8, 8.2, 13.5, 13.5, 10.5, 10.5],
          close: true,
          fill: true,
          opacity: .72,
        );
      });
    case ArchiveSymbol.shelf:
      a.poly([2.5, 19.6, 2.5, 21, 21.5, 21]);
      a.move(0, -1.7 * p, () {
        a.card(3.6, 6, 4.8, 13.6, fold: 1.5, shade: .19);
        a.line(5.2, 9.2, 6.8, 9.2);
      });
      a.move(0, -2.4 * q, () {
        a.card(10, 3.9, 4.5, 15.7, fold: 1.5, shade: .09 + active * .15);
        a.line(11.6, 7, 12.8, 7);
      });
      a.move(
        0,
        -.8 * r,
        () => a.transform(
          angle: -.12 - r * .15,
          pivot: const Offset(19, 20),
          draw: () => a.card(17.1, 6.2, 4.1, 13.4, fold: 1.3, shade: .08),
        ),
      );
    case ArchiveSymbol.book:
      a.path(
        (s) => s
            .m(3.1, 6)
            .q(7.5, 4.1 - .7 * p, 12, 7)
            .q(16, 4.3 - .7 * r, 20.9, 6)
            .l(20.3, 18.6)
            .q(16.1, 17.8, 12, 20)
            .q(7.9, 17.8, 3.7, 18.6)
            .z(),
        fill: true,
        opacity: .06 + active * .13,
      );
      a.path(
        (s) => s
            .m(3.1, 6)
            .q(7.5, 4.1 - .7 * p, 12, 7)
            .q(16, 4.3 - .7 * r, 20.9, 6)
            .l(20.3, 18.6)
            .q(16.1, 17.8, 12, 20)
            .q(7.9, 17.8, 3.7, 18.6)
            .z(),
      );
      a.poly([3.5, 21, 8.1, 20.3, 12, 21.5, 15.9, 20.3, 20.5, 21], opacity: .5);
      a.path((s) => s.m(12, 7).l(12, 20));
      // A real turning leaf sweeps across the gutter, not a scaled book.
      a.path(
        (s) => s
            .m(12, 7)
            .q(16.6 - 8 * q, 2.3 - p, 19.6 - 6.5 * q, 4.7)
            .l(19.5 - 6.5 * q, 16.9)
            .q(15 - 4 * q, 16.6, 12, 20),
      );
      a.line(5.7, 9.5, 8.8, 10.1);
    case ArchiveSymbol.folder:
    case ArchiveSymbol.folderOpen:
    case ArchiveSymbol.folderAdd:
      a.card(6, 4.6 - 2.6 * q, 12.6, 13.3, fold: 2.8, shade: .12);
      final open = (pose.symbol == ArchiveSymbol.folderOpen ? .6 : 0) + p;
      a.path(
        (s) => s
            .m(3, 8.4 + 2.1 * open)
            .l(8, 8.4 + 2.1 * open)
            .l(10.4, 10 + 2.1 * open)
            .l(21.5, 10 + 2.1 * open)
            .l(19.7, 20.2)
            .l(4.4, 20.2)
            .z(),
        fill: true,
        opacity: .11 + active * .10,
      );
      a.path(
        (s) => s
            .m(3, 8.4 + 2.1 * open)
            .l(8, 8.4 + 2.1 * open)
            .l(10.4, 10 + 2.1 * open)
            .l(21.5, 10 + 2.1 * open)
            .l(19.7, 20.2)
            .l(4.4, 20.2)
            .z(),
      );
      if (pose.symbol == ArchiveSymbol.folderAdd) {
        a.line(10, 15.4, 15, 15.4);
        a.line(12.5, 12.9, 12.5, 17.9);
      } else {
        a.line(7.2, 17.2, 12.6, 17.2);
      }
    case ArchiveSymbol.profile:
      a.circle(
        12,
        8.4 - p * .9,
        3.3,
        fill: true,
        opacity: .11 + active * .12,
      );
      a.circle(12, 8.4 - p * .9, 3.3);
      a.path(
        (s) => s
            .m(5.2, 19.4)
            .c(5.8, 13.9 - .7 * q, 18.2, 13.9 - .7 * q, 18.8, 19.4),
      );
    case ArchiveSymbol.forward:
      a.rotate(v, () {
        a.poly([9.2 + 1.0 * q, 5.8, 15.4 + 1.3 * p, 12, 9.2 + 1.0 * q, 18.2]);
      });
    case ArchiveSymbol.arrowRight:
      a.rotate(v, () {
        a.line(4.2 - .4 * r, 12, 19 + 1.2 * p, 12);
        a.poly([13.2 + 1.0 * q, 6.0, 19 + 1.2 * p, 12, 13.2 + 1.0 * q, 18.0]);
      });
    case ArchiveSymbol.close:
    case ArchiveSymbol.closeCircle:
      if (pose.symbol == ArchiveSymbol.closeCircle) a.ring();
      final d = pose.symbol == ArchiveSymbol.closeCircle ? 3.0 : 5.4;
      a.rotate(p * .45, () {
        a.line(12 - d, 12 - d, 12 + d, 12 + d);
        a.line(12 + d, 12 - d, 12 - d, 12 + d);
      });
    case ArchiveSymbol.more:
      for (var i = 0; i < 3; i++) {
        final bounce = [p, q, r][i];
        a.dot(5.5 + i * 6.5, 12 - bounce * 2.2, 1.35);
      }
    case ArchiveSymbol.contents:
      for (var i = 0; i < 3; i++) {
        final x = [p, q, r][i] * 1.6;
        final y = 6.2 + i * 5.8;
        a.dot(4.6 + x, y, 1.15);
        a.line(8.2 + x, y, 20.0 - (i == 1 ? 2.8 : 0), y);
      }
    case ArchiveSymbol.bookmark:
      final top = 3.2 + 1.8 * q, bottom = 21 - 1.1 * r;
      a.path(
        (s) => s
            .m(6, top)
            .l(14.8, top)
            .l(18, top + 3.2)
            .q(18 + 2.1 * p, 12, 18, bottom)
            .l(12, bottom - 4.2)
            .l(6, bottom)
            .z(),
        fill: true,
        opacity: .09 + v.clamp(0, 1) * .76 + active * .06,
      );
      a.path(
        (s) => s
            .m(6, top)
            .l(14.8, top)
            .l(18, top + 3.2)
            .q(18 + 2.1 * p, 12, 18, bottom)
            .l(12, bottom - 4.2)
            .l(6, bottom)
            .z(),
      );
      a.poly([14.8, top, 14.8 - 1.2 * p, top + 3.2, 18, top + 3.2]);
      a.line(9, top + 5.5, 12, top + 5.5);
    case ArchiveSymbol.location:
      a.transform(
        x: .8 * p,
        y: -.8 * p,
        angle: -.13 * q,
        draw: () {
          a.poly([3.4, 9.8, 20.4, 3.6, 14.2, 20.6, 10.6, 13.4], close: true);
          a.poly(
            [10.6, 13.4, 20.4, 3.6, 14.2, 20.6],
            close: true,
            fill: true,
            opacity: .15 + v.clamp(0, 1) * .2,
          );
          a.line(10.6, 13.4, 20.4, 3.6);
        },
      );
    case ArchiveSymbol.touch:
      // The index finger presses while the curled fingers follow. The wrist
      // stays anchored, so this reads as contact rather than a moving pointer.
      final press = p.clamp(-.12, 1.0), curl = q.clamp(-.12, 1.0);
      a.path(
        (s) => s
            .m(16.7, 14.9)
            .l(19.3, 14.5)
            .l(19.3, 15.6)
            .q(19.3, 18.4, 17.6, 20.1)
            .l(17.6, 21)
            .l(15.8, 21)
            .q(17.4, 17.5, 16.7, 14.9)
            .z(),
        fill: true,
        opacity: .10 + active * .12,
      );
      a.path(
        (s) => s
            .m(8.2, 13.2)
            .l(8.2 + .2 * press, 5.9 + 1.05 * press)
            .c(
              8.2 + .2 * press,
              3.7 + press,
              11.6 + .2 * press,
              3.7 + press,
              11.6 + .2 * press,
              5.9 + 1.05 * press,
            )
            .l(11.6, 10.4)
            .c(12.7, 9.2 - .3 * curl, 14.3, 9.6, 14.3, 11.1)
            .c(15.1, 10 - .25 * curl, 16.7, 10.4, 16.7, 11.8)
            .c(17.8, 10.9, 19.3, 11.7, 19.3, 13.2)
            .l(19.3, 15.6)
            .q(19.3, 18.4, 17.6, 20.1)
            .l(17.6, 21)
            .l(10, 21)
            .l(10, 20.4)
            .q(8.8, 19.7, 7.7, 18.1)
            .l(4.4 + .3 * curl, 13.9)
            .c(3.4 + .3 * curl, 12.6, 4.9, 11, 6.1, 12)
            .l(8.2, 14.1)
            .z(),
      );
      a.line(11.6, 10.4, 11.6, 13.1 + .4 * curl);
      a.line(14.3, 11.1, 14.3, 13.6 + .3 * r);
      a.line(16.7, 11.8, 16.7, 14);
      a.line(10.2, 1.6 - .3 * r, 10.2, 2.5 - .15 * r);
      a.line(5.6 - .35 * r, 3 - .25 * r, 6.5 - .15 * r, 3.8 - .1 * r);
      a.line(14.8 + .35 * r, 3 - .25 * r, 13.9 + .15 * r, 3.8 - .1 * r);
    case ArchiveSymbol.typography:
      a.path(
        (s) =>
            s.m(3.4, 7.5).l(4, 4.8 - .5 * p).l(16.2, 4.8 - .5 * q).l(16.8, 7.5),
      );
      a.path((s) => s.m(10.1, 5).l(10.1 + 1.1 * p, 19.8), width: 1.35);
      a.line(6.6, 20, 14.1, 20);
      a.line(17.6, 12 - 1.2 * r, 21, 12 - 1.2 * r);
      a.line(17.6, 16, 20.2, 16);
      a.mark(17.6, 19.2, 1.3);
    case ArchiveSymbol.sliders:
      for (var i = 0; i < 3; i++) {
        final x = 5.5 + 6.5 * i;
        final y = [8.0 + 4 * p, 15.0 - 5 * q, 7.0 + 5 * r][i];
        a.line(x, 3, x, y - 2.1);
        a.line(x, y + 2.1, x, 21);
        a.poly(
          [
            x - 2.1,
            y - 1.6,
            x + .9,
            y - 1.6,
            x + 2.1,
            y - .4,
            x + 2.1,
            y + 1.6,
            x - 2.1,
            y + 1.6,
          ],
          close: true,
          fill: true,
          opacity: .22,
        );
        a.poly([
          x - 2.1,
          y - 1.6,
          x + .9,
          y - 1.6,
          x + 2.1,
          y - .4,
          x + 2.1,
          y + 1.6,
          x - 2.1,
          y + 1.6,
        ], close: true);
      }
    case ArchiveSymbol.image:
      a.card(3.3, 4, 17.4, 16.2, fold: 3.1 + p, shade: .08);
      a.circle(8, 8.9 - 1.7 * q, 1.35, fill: true);
      a.poly([
        3.6,
        17,
        8.2,
        12.2 - p,
        11.9,
        15.5,
        15.8,
        11.6 - 1.9 * r,
        20.4,
        17,
      ]);
    case ArchiveSymbol.brightness:
      a.circle(12, 12, 3.8 - .6 * q);
      a.path(
        (s) => s.m(12, 8.2).c(6.9, 8.2, 6.9, 15.8, 12, 15.8).z(),
        fill: true,
        opacity: .22,
      );
      a.rotate(p * .62, () {
        for (var i = 0; i < 8; i++) {
          final t = i * math.pi / 4, inner = 6.7 + (i.isEven ? p : r) * .7;
          a.line(
            12 + inner * math.cos(t),
            12 + inner * math.sin(t),
            12 + 9.2 * math.cos(t),
            12 + 9.2 * math.sin(t),
          );
        }
      });
    case ArchiveSymbol.moon:
      a.rotate(p * -.30, () {
        void moon(_Trace s) => s
            .m(17.8, 15.2)
            .c(10.1, 17.2, 7, 10.2, 9.5, 3.6)
            .c(3.5, 5.4, 2.6, 13, 6.4, 17.5)
            .c(10.4, 21.8, 17, 21.1, 20, 15)
            .q(18.8, 15.8, 17.8, 15.2)
            .z();
        a.path(moon, fill: true, opacity: .13);
        a.path(moon);
      });
      a.star(17.5, 6.3, 1.8 + .8 * q);
    case ArchiveSymbol.layers:
      a.poly([3.5, 16.4, 12, 21, 20.5, 16.4]);
      a.poly([3.5, 12.2 - 1.4 * q, 12, 16.8 - 1.4 * q, 20.5, 12.2 - 1.4 * q]);
      a.poly(
        [
          3.5,
          7.8 - 1.9 * p,
          12,
          3.2 - 1.5 * p,
          20.5,
          7.8 - 1.9 * p,
          12,
          12.4 - 1.9 * p,
        ],
        close: true,
        fill: true,
        opacity: .13,
      );
      a.poly([
        3.5,
        7.8 - 1.9 * p,
        12,
        3.2 - 1.5 * p,
        20.5,
        7.8 - 1.9 * p,
        12,
        12.4 - 1.9 * p,
      ], close: true);
      a.line(12, 3.2 - 1.5 * p, 12, 6.4 - 1.5 * p);
    case ArchiveSymbol.quotes:
      for (var i = 0; i < 2; i++) {
        final x = 3.8 + i * 9, y = 5.6 - [p, q][i] * 2.2;
        a.card(x, y, 6.8, 7.3, fold: 1.9, shade: .26);
        a.path((s) => s.m(x + 6.8, y + 7.3).q(x + 6, 18.8, x + 1.8, 19.7));
      }
    case ArchiveSymbol.language:
      a.move(0, -p * 1.4, () {
        a.poly([2.9, 6.2, 13.2, 6.2]);
        a.line(8.1, 3.2, 8.1, 6.2);
        a.path((s) => s.m(11.4, 6.3).q(10, 13.5, 3.3, 16.3));
        a.path((s) => s.m(5, 9.5).q(7.6, 13.3, 11.2, 14.5));
      });
      a.move(0, q * 1.4, () {
        a.poly([12.6, 20, 17.1, 9.2, 21.5, 20]);
        a.line(14.1, 16.6, 20, 16.6);
      });
      a.mark(16.5, 3.8, 1.3, angle: math.pi / 4);
    case ArchiveSymbol.portrait:
      a.card(6.7, 2.7, 10.6, 18.6, fold: 2.5, shade: .09);
      a.line(10.4, 18.5, 13.6, 18.5);
      a.card(9.4, 9.7, 5.2, 4.8, fold: 1.1, shade: .18);
      a.path(
        (s) => s
            .m(10.4, 9.7)
            .l(10.4, 7.9 - 1.1 * p)
            .c(10.4, 5.5 - p, 13.6, 5.5 - p, 13.6, 7.9 - 1.1 * p)
            .l(13.6, 9.7),
      );
    case ArchiveSymbol.headphones:
      a.path(
        (s) => s
            .m(4.4, 14)
            .l(4.4, 10.4)
            .c(4.4, 1.8 + p * 1.4, 19.6, 1.8 + q * 1.4, 19.6, 10.4)
            .l(19.6, 14),
      );
      a.rect(
        3.2,
        12 - 1.2 * p,
        4.4,
        7.6,
        radius: 1.9,
        fill: true,
        opacity: .16 + active * .12,
      );
      a.rect(3.2, 12 - 1.2 * p, 4.4, 7.6, radius: 1.9);
      a.rect(
        16.4,
        12 - 1.2 * q,
        4.4,
        7.6,
        radius: 1.9,
        fill: true,
        opacity: .16 + active * .12,
      );
      a.rect(16.4, 12 - 1.2 * q, 4.4, 7.6, radius: 1.9);
    case ArchiveSymbol.play:
      final t = v.clamp(0.0, 1.0);
      double mix(double x, double y) => x + (y - x) * t;
      a.path(
        (s) => s
            .m(mix(7.0, 6.4), 4.7)
            .l(mix(7.0, 6.4), 19.3)
            .l(mix(13.2, 10.2) + .7 * p, mix(15.6, 19.3))
            .l(mix(13.2, 10.2) - .5 * p, mix(8.4, 4.7))
            .z(),
        fill: true,
      );
      a.path(
        (s) => s
            .m(mix(13.0, 13.8) - .5 * p, mix(8.3, 4.7))
            .l(mix(13.0, 13.8) + .7 * p, mix(15.7, 19.3))
            .l(mix(19.5, 17.6) + .6 * q, mix(12, 19.3))
            .l(mix(19.5, 17.6) - .4 * q, mix(12, 4.7))
            .z(),
        fill: true,
      );
    case ArchiveSymbol.stop:
      a.rect(
        5.5 + p * .4,
        5.5 + q * .4,
        13.0 - p * .8,
        13.0 - q * .8,
        radius: 2.2,
        fill: true,
      );
    case ArchiveSymbol.previous:
    case ArchiveSymbol.next:
      a.rotate(pose.symbol == ArchiveSymbol.previous ? math.pi : 0, () {
        a.poly(
          [4.8 + 1.6 * p, 5.6, 4.8 + 1.6 * p, 18.4, 14.8 + 1.6 * q, 12],
          close: true,
          fill: true,
          opacity: .17,
        );
        a.poly([
          4.8 + 1.6 * p,
          5.6,
          4.8 + 1.6 * p,
          18.4,
          14.8 + 1.6 * q,
          12,
        ], close: true);
        a.line(19.2, 5.4, 19.2 - .4 * r, 18.6);
      });
    case ArchiveSymbol.waveform:
      for (var i = 0; i < 5; i++) {
        final h =
            ([3.2, 5.8, 8.5, 5.8, 3.2][i] +
                    [p, q, r, p, q][i] * (i.isEven ? -2.0 : 2.2))
                .clamp(1.2, 10.1);
        a.path(
          (s) => s.m(4 + i * 4, 12 - h).l(4 + i * 4, 12 + h),
          width: i == 2 ? 1.3 : 1,
        );
      }
    case ArchiveSymbol.voice:
      a.rect(
        9,
        3.2,
        6,
        10.8,
        radius: 3,
        fill: true,
        opacity: .14 + active * .12,
      );
      a.rect(9, 3.2, 6, 10.8, radius: 3);
      a.path(
        (s) => s
            .m(5.8, 10.8)
            .l(5.8, 12 - .8 * p)
            .c(5.8, 19.8 + 1.2 * q, 18.2, 19.8 + 1.2 * r, 18.2, 12 - .8 * p)
            .l(18.2, 10.8),
      );
      a.line(12, 17.9, 12, 21.0);
      a.line(9.2, 21.0, 14.8, 21.0);
    case ArchiveSymbol.volume:
      a.poly(
        [3.2, 9.3, 7, 9.3, 12, 4.8, 12, 19.2, 7, 14.7, 3.2, 14.7],
        close: true,
        fill: true,
        opacity: .13,
      );
      a.poly([
        3.2,
        9.3,
        7,
        9.3,
        12,
        4.8,
        12,
        19.2,
        7,
        14.7,
        3.2,
        14.7,
      ], close: true);
      a.path(
        (s) => s
            .m(15.4 + .6 * p, 8.6 - p)
            .q(20.2 + p, 12, 15.4 + .6 * p, 15.4 + p),
      );
      a.path(
        (s) => s
            .m(18.2 + .7 * q, 5.6 - .8 * q)
            .q(24.4 + .4 * q, 12, 18.2 + .7 * q, 18.4 + .8 * q),
      );
    case ArchiveSymbol.speed:
      a.arc(12, 13.2, 8.4, 8.4, math.pi * .85, math.pi * 1.3);
      a.rotate(
        p * .75,
        () => a.poly([10.9, 13, 15.7, 6.9, 13, 14.4], close: true, fill: true),
      );
      a.dot(12, 13.2, 1.2);
      a.line(8, 20.6, 16, 20.6);
      a.line(6, 7.9, 7.1, 9);
      a.line(12, 4.8, 12, 6.1);
      a.line(18, 7.9, 16.9, 9);
    case ArchiveSymbol.timer:
      a.ring();
      a.rotate(p * .45, () {
        a.poly([12, 6.5, 12, 12, 16.1, 14.5]);
      });
      a.dot(12, 12, 1.0);
    case ArchiveSymbol.search:
      a.move(.5 * p, -.5 * p, () {
        a.circle(
          10.5,
          10.5,
          6.4 - .3 * q,
          fill: true,
          opacity: .06 + active * .10,
        );
        a.circle(10.5, 10.5, 6.4 - .3 * q);
        a.path(
          (s) => s.m(15.1, 15.1).l(20.2 + .4 * r, 20.2 + .4 * r),
          width: 1.25,
        );
      });
    case ArchiveSymbol.filter:
      // Three calibrated tracks: the blocks move independently, while the
      // fixed rails retain a clear filter silhouette throughout the gesture.
      for (var i = 0; i < 3; i++) {
        final y = 5.5 + i * 6.5;
        final x = [8.0 + 4 * p, 16.0 - 4 * q, 10.0 + 3.5 * r][i];
        a.path((s) => s.m(3.5, y).l(x - 2.5, y), width: .88);
        a.path((s) => s.m(x + 2.5, y).l(20.5, y), width: .88);
        a.rect(x - 1.4, y - 2, 2.8, 4, radius: .8, fill: true);
      }
    case ArchiveSymbol.layout:
      // The same three units reflow from a sidebar into a header + two cells.
      // No global spin/scale: this action demonstrates what its view changes.
      final lead = p.clamp(-.12, 1.0);
      final follow = q.clamp(-.12, 1.0);
      final trail = r.clamp(-.12, 1.0);
      a.rect(3.5, 4, 5.5 + 11.5 * lead, 16 - 10.5 * lead, radius: 1.2);
      a.rect(
        3.5,
        4,
        5.5 + 11.5 * lead,
        16 - 10.5 * lead,
        radius: 1.2,
        fill: true,
        opacity: .08 + active * .13,
      );
      a.rect(
        12 - 8.5 * follow,
        4 + 8.5 * follow,
        8.5 - 1.5 * follow,
        6.5 + follow,
        radius: 1.2,
      );
      a.rect(
        12 + 1.5 * trail,
        13.5 - trail,
        8.5 - 1.5 * trail,
        6.5 + trail,
        radius: 1.2,
      );
    case ArchiveSymbol.grid:
      for (var i = 0; i < 4; i++) {
        final d = [p, q, r, q][i];
        final x = 4.0 + i % 2 * 10;
        final y = 4.0 + i ~/ 2 * 10 - d * 1.1;
        a.rect(x, y, 6, 6, radius: 1.2);
        if (i == 0) {
          a.rect(
            x,
            y,
            6,
            6,
            radius: 1.2,
            fill: true,
            opacity: .14 + active * .12,
          );
        }
      }
    case ArchiveSymbol.dotsGrid:
      for (var i = 0; i < 9; i++) {
        final d = [p, q, r][i ~/ 3];
        a.dot(5.0 + i % 3 * 7, 5.0 + i ~/ 3 * 7 - d * 1.4, 1.2);
      }
    case ArchiveSymbol.add:
    case ArchiveSymbol.addCircle:
    case ArchiveSymbol.removeCircle:
      if (pose.symbol != ArchiveSymbol.add) a.ring();
      final length = pose.symbol == ArchiveSymbol.add ? 6.4 : 3.7;
      a.rotate(p * .30, () {
        a.line(12 - length, 12, 12 + length, 12);
        if (pose.symbol != ArchiveSymbol.removeCircle) {
          a.path((s) => s.m(12, 12 - length).l(12, 12 + length), width: 1.1);
        }
      });
    case ArchiveSymbol.check:
      a.poly([4.6, 12.6, 9.6, 17.5 + .6 * q, 19.8, 6.6 - .9 * p]);
    case ArchiveSymbol.circle:
      a.circle(12, 12, 8.4, fill: true, opacity: (v - 1).clamp(0, 1) * .21);
      a.ring();
      if (v > 0) {
        final t = v.clamp(0.0, 1.0);
        final corner = const Offset(7.5, 12.1),
            middle = Offset(10.7, 15.5 + .5 * q),
            end = Offset(16.7, 8.5 - .6 * p);
        final l1 = (middle - corner).distance, l2 = (end - middle).distance;
        final d = (l1 + l2) * t;
        a.path((s) {
          s.m(corner.dx, corner.dy);
          if (d <= l1) {
            final e = Offset.lerp(corner, middle, d / l1)!;
            s.l(e.dx, e.dy);
          } else {
            final e = Offset.lerp(middle, end, (d - l1) / l2)!;
            s.l(middle.dx, middle.dy).l(e.dx, e.dy);
          }
        });
      }
    case ArchiveSymbol.edit:
      a.move(.7 * p, -.7 * p, () {
        a.poly([
          3.8,
          20.2,
          5.8,
          13.2,
          15.8,
          3.2,
          20.6,
          8.0,
          10.6,
          18.0,
        ], close: true);
        a.poly(
          [3.8, 20.2, 5.8, 13.2, 10.6, 18.0],
          close: true,
          fill: true,
          opacity: .16,
        );
        a.line(13.2, 5.8, 18.0, 10.6);
      });
    case ArchiveSymbol.delete:
      a.path(
        (s) => s
            .m(5.8, 8.8)
            .l(6.6, 18.7)
            .q(6.7, 20.2, 8.2, 20.2)
            .l(15.8, 20.2)
            .q(17.3, 20.2, 17.4, 18.7)
            .l(18.2, 8.8),
      );
      a.line(10.0, 11.2, 10.2, 17.2);
      a.line(14.0, 11.2, 13.8, 17.2);
      a.transform(
        y: -1.3 * p,
        angle: -.07 * q,
        pivot: const Offset(5, 7),
        draw: () {
          a.line(4.0, 6.7, 20.0, 6.7);
          a.poly([9.2, 6.7, 9.2, 4.2, 14.8, 4.2, 14.8, 6.7]);
        },
      );
    case ArchiveSymbol.copy:
      a.card(3.5, 3.2, 12, 14, fold: 2.7, shade: .07);
      a.move(
        1.5 * p,
        -1.9 * q,
        () => a.card(8.2, 7.1, 12, 14, fold: 2.7, shade: .15),
      );
    case ArchiveSymbol.share:
      a.poly([4.2, 11.7, 4.2, 18.6, 6.1, 20.5, 19.8, 20.5, 19.8, 11.7]);
      a.line(12, 15.2 - .6 * r, 12, 3.7 - p);
      a.poly([7.7, 8 - q, 12, 3.7 - p, 16.3, 8 - q]);
    case ArchiveSymbol.link:
      a.move(
        .9 * p,
        -.9 * p,
        () => a.path(
          (s) => s
              .m(10, 7.9)
              .l(12.8, 5.1)
              .c(18.2, -.2, 24, 5.6, 18.7, 11)
              .l(16.3, 13.5),
        ),
      );
      a.move(
        -.9 * q,
        .9 * q,
        () => a.path(
          (s) => s
              .m(14, 16.1)
              .l(11.2, 18.9)
              .c(5.8, 24.2, 0, 18.4, 5.3, 13)
              .l(7.7, 10.5),
        ),
      );
      a.line(8.6 + .8 * r, 15.4 - .8 * r, 15.4 - .8 * r, 8.6 + .8 * r);
    case ArchiveSymbol.refresh:
      a.rotate(p * math.pi, () {
        a.arc(12, 12, 7.8, 7.8, -.6, math.pi * 1.77);
        a.poly([19.1, 3.5, 19.1, 8.3, 14.3, 8.3]);
      });
    case ArchiveSymbol.sync:
      a.rotate(p * math.pi * .8, () {
        a.path((s) => s.m(4.2, 9).c(6, 1, 18, 1, 19.8, 9));
        a.poly([19.8, 4.2, 19.8, 9, 15, 9]);
        a.path((s) => s.m(19.8, 15).c(18, 23, 6, 23, 4.2, 15));
        a.poly([4.2, 19.8, 4.2, 15, 9, 15]);
      });
    case ArchiveSymbol.download:
      a.poly([3.5, 16.8, 3.5, 18.9, 5.5, 20.7, 20.5, 20.7, 20.5, 16.8]);
      a.line(12, 3.2 + 2.5 * q, 12, 14.5 + 2.5 * p);
      a.poly([7.5, 10 + 2.5 * p, 12, 14.5 + 2.5 * p, 16.5, 10 + 2.5 * p]);
    case ArchiveSymbol.cloudDownload:
      a.path(
        (s) => s
            .m(6.4, 17.3)
            .c(-.5, 17.3, .7, 8.2, 6.7, 8.5)
            .c(6.5, 1.5 - p, 17.3, 1.5 - q, 17.8, 8.4)
            .c(23.4, 8.2, 24, 17.3, 18, 17.3),
      );
      a.line(12, 10.6 + 1.3 * q, 12, 19.7 + 1.3 * p);
      a.poly([8.8, 16.5 + 1.3 * p, 12, 19.7 + 1.3 * p, 15.2, 16.5 + 1.3 * p]);
    case ArchiveSymbol.upload:
      a.ring();
      a.poly([8, 11.8 - 1.8 * q, 12, 7.8 - 1.8 * p, 16, 11.8 - 1.8 * q]);
      a.line(12, 7.8 - 1.8 * p, 12, 17.2);
    case ArchiveSymbol.importFile:
    case ArchiveSymbol.document:
      a.card(5, 3, 14, 18, fold: 4, shade: .11);
      if (pose.symbol == ArchiveSymbol.document) {
        a.line(8.2, 11.2, 15.8 - 2.4 * p, 11.2);
        a.line(8.2, 14.7, 15.8 - 2.4 * q, 14.7);
        a.line(8.2, 18.2, 12.5 - r, 18.2);
      } else {
        a.line(12, 10.4 + q, 12, 17.3 + p);
        a.poly([9, 14.3 + p, 12, 17.3 + p, 15, 14.3 + p]);
      }
    case ArchiveSymbol.wand:
      a.poly(
        [3.8, 19.5, 13.4, 9.9, 15.5, 12, 5.9, 21.6],
        close: true,
        fill: true,
        opacity: .17,
      );
      a.poly([3.8, 19.5, 13.4, 9.9, 15.5, 12, 5.9, 21.6], close: true);
      a.rotate(p * .38, () => a.star(17.4, 5.8, 2.5 + .9 * q));
      a.star(5.5, 6.8, 1.5 + .7 * r);
      a.mark(19.3, 15.3, 1.2, angle: .785);
    case ArchiveSymbol.settings:
      a.rotate(p * math.pi / 3, () {
        final points = <double>[];
        for (var i = 0; i < 36; i++) {
          final angle = i * math.pi / 18 - math.pi / 2;
          final radius = switch (i % 6) {
            0 || 5 => 7.1,
            _ => 8.9,
          };
          points.addAll([
            12 + radius * math.cos(angle),
            12 + radius * math.sin(angle),
          ]);
        }
        a.poly(points, close: true);
        a.circle(12, 12, 3.3);
        a.poly(
          [9.7, 9.7, 12, 8.7, 12, 15.3, 9.7, 14.3],
          close: true,
          fill: true,
          opacity: .25,
        );
      });
    case ArchiveSymbol.info:
    case ArchiveSymbol.help:
      a.ring();
      if (pose.symbol == ArchiveSymbol.info) {
        a.dot(12, 7.6 - 1.0 * p, 1.1);
        a.poly([10.8, 11.2, 12.2, 11.2, 12.2, 16.8, 13.8, 16.8]);
      } else {
        a.path(
          (s) => s
              .m(9.3, 8.5 - .8 * p)
              .c(9.3, 5.0 - .8 * p, 15.8, 5.0 - .8 * q, 14.9, 9.4)
              .c(14.6, 10.8, 12, 11.2, 12, 13.7),
        );
        a.dot(12, 17.2, 1.1);
      }
    case ArchiveSymbol.warning:
      a.poly(
        [12, 3.6, 21.1, 19.8, 2.9, 19.8],
        close: true,
        fill: true,
        opacity: .08 + active * .10,
      );
      a.poly([12, 3.6, 21.1, 19.8, 2.9, 19.8], close: true);
      a.path((s) => s.m(12, 9.0 - .7 * p).l(12, 14.0 - .7 * p), width: 1.15);
      a.dot(12, 17.0 - .4 * q, 1.05);
    case ArchiveSymbol.wifi:
    case ArchiveSymbol.wifiOff:
    case ArchiveSymbol.wifiWarning:
      for (var i = 0; i < 3; i++) {
        final x = 3.1 + 3 * i, y = 8 + i * 3.8 - [p, q, r][i] * 1.3;
        a.path((s) => s.m(x, y).q(12, y - (6.4 - i * 2.1), 24 - x, y));
      }
      a.dot(12, 18.8, 1.3);
      if (pose.symbol == ArchiveSymbol.wifiOff) a.line(3.2, 3.5, 20.8, 21.1);
      if (pose.symbol == ArchiveSymbol.wifiWarning) {
        a.line(21.2, 12.4, 21.2, 16.3);
        a.dot(21.2, 19.1, .9);
      }
    case ArchiveSymbol.cloud:
      a.path(
        (s) => s
            .m(6.4, 18.6)
            .c(-.3, 18.6, .5, 8, 6.8, 8.6)
            .c(7, 1.7 - p * 1.5, 18.2, 1.7 - q * 1.5, 18.2, 9.4)
            .c(24, 10.6, 22.6, 18.6, 18, 18.6)
            .z(),
      );
      a.poly(
        [14.4, 18.6, 17, 15.9, 17, 18.6],
        close: true,
        fill: true,
        opacity: .23,
      );
    case ArchiveSymbol.globe:
      a.ring();
      a.ellipse(12 + .9 * p, 12, 3.9 - 1.8 * q, 8.4);
      a.line(3.6, 12, 20.4, 12);
      a.path((s) => s.m(5.6, 6.6).q(12, 10.3, 18.4, 6.6));
      a.path((s) => s.m(5.6, 17.4).q(12, 13.7, 18.4, 17.4));
    case ArchiveSymbol.phone:
      a.rotate(p * .14, () {
        a.card(6.6, 2.8, 10.8, 18.4, fold: 2.5, shade: .07);
        a.line(10, 5.5, 13.7, 5.5);
        a.line(10.4, 18.5, 13.6, 18.5);
      });
    case ArchiveSymbol.laptop:
      a.card(4.5, 4.2 + 2.8 * p, 15, 12.2 - 2.8 * p, fold: 2.6, shade: .08);
      a.poly([4.5, 16.4, 2.3, 20.2, 21.7, 20.2, 19.5, 16.4]);
      a.line(10, 18.2, 14, 18.2);
    case ArchiveSymbol.branch:
      a.line(7, 6.5, 7, 17.5);
      a.path((s) => s.m(7, 14).c(7, 10, 17 + 1.5 * p, 13, 17 + 1.5 * p, 6.5));
      a.card(5.2, 2.8, 3.6, 3.6, fold: 1, shade: .15);
      a.card(15.2 + 1.5 * p, 2.8, 3.6, 3.6, fold: 1, shade: .15);
      a.card(5.2, 17.6, 3.6, 3.6, fold: 1, shade: .15);
    case ArchiveSymbol.personAdd:
      a.circle(9.2, 7 - 1.4 * p, 3.1);
      a.path(
        (s) => s
            .m(3.3, 20)
            .l(3.3, 18)
            .c(3.3, 12 - q, 15.1, 12 - q, 15.1, 18)
            .l(15.1, 20),
      );
      a.transform(
        angle: p * math.pi / 2,
        pivot: const Offset(19, 10),
        draw: () {
          a.line(19, 7.2, 19, 12.8);
          a.line(16.2, 10, 21.8, 10);
        },
      );
    case ArchiveSymbol.eye:
      final aperture = (1 - p.clamp(0, 1.15) * .80).clamp(.08, 1.3);
      a.path(
        (s) => s
            .m(2.7, 12)
            .c(7, 12 - 8 * aperture, 17, 12 - 8 * aperture, 21.3, 12)
            .c(17, 12 + 8 * aperture, 7, 12 + 8 * aperture, 2.7, 12)
            .z(),
      );
      a.ellipse(12, 12, 2.9, 2.9 * aperture);
      a.circle(12, 12, .9 * aperture, fill: true);
      if (v > 0) {
        a.line(
          4,
          4,
          4 + v.clamp(0, 1) * 16,
          4 + v.clamp(0, 1) * 16,
          opacity: v.clamp(0, 1),
        );
      }
    case ArchiveSymbol.battery:
      a.card(2.8, 7, 16.5, 10, fold: 1.7, shade: 0);
      a.line(21.8, 10, 21.8, 14);
      a.rect(5.2, 9.4, 11.7, 5.2, radius: .2, fill: true);
    case ArchiveSymbol.charging:
      a.poly(
        [13.1, 2.7, 5.3, 12.8, 11.2, 12.8, 10.6, 21.3, 18.7, 10.2, 12.8, 10.2],
        close: true,
        fill: true,
      );
    case ArchiveSymbol.tools:
      a.transform(
        angle: p * .17,
        scale: .94,
        draw: () => a.path(
          (s) => s
              .m(13, 5.1)
              .c(14.1, 2.5, 16.8, 2, 19, 3)
              .l(15.5, 6.5)
              .l(17.5, 8.5)
              .l(21, 5)
              .c(23.1, 10, 18.7, 13.1, 15.3, 11.8)
              .l(7.1, 20)
              .c(4.2, 22.9, 1.1, 19.8, 4, 16.9)
              .l(12.3, 8.6)
              .q(11.5, 7, 13, 5.1),
        ),
      );
    case ArchiveSymbol.shield:
      a.path(
        (s) => s
            .m(12, 2.9)
            .l(19.7, 5.5)
            .l(18.7, 14)
            .q(17.5, 18.6, 12, 21.2)
            .q(6.5, 18.6, 5.3, 14)
            .l(4.3, 5.5)
            .z(),
      );
      a.poly([8, 11.7 + q, 10.8, 14.4 + .5 * q, 16, 9.2 - p]);
    case ArchiveSymbol.tag:
      a.transform(
        angle: -.08 * p,
        pivot: const Offset(8, 8),
        draw: () {
          void tagContour(_Trace s) => s
              .m(4.2, 4.2)
              .l(11.6, 4.2)
              .l(20.1, 12.7)
              .l(12.7, 20.1)
              .l(4.2, 11.6)
              .z();
          a.path(tagContour, fill: true, opacity: .10 + active * .12);
          a.path(tagContour);
          a.circle(8.2, 8.2, 1.45, fill: true);
        },
      );
    case ArchiveSymbol.chart:
      final heights = [8.0 + 1.8 * p, 14.5 + 1.6 * q, 11.2 + 1.8 * r];
      for (var i = 0; i < 3; i++) {
        final x = 4.2 + i * 6.0;
        final h = heights[i].clamp(4.0, 16.8);
        a.rect(
          x,
          20.0 - h,
          3.6,
          h,
          radius: 1.0,
          fill: true,
          opacity: i == 1 ? .22 + active * .14 : .11 + active * .08,
        );
        a.rect(x, 20.0 - h, 3.6, h, radius: 1.0);
      }
      a.line(3.2, 20.0, 20.8, 20.0);
    case ArchiveSymbol.palette:
      a.rotate(p * .18, () {
        void paletteContour(_Trace s) => s
            .m(12, 3.4)
            .c(17.4, 3.4, 21.0, 7.2, 20.8, 11.8)
            .c(20.6, 14.4, 18.4, 15.6, 16.4, 15.2)
            .c(14.7, 14.9, 13.8, 16.0, 14.2, 17.5)
            .c(14.6, 19.3, 13.2, 20.6, 11.2, 20.6)
            .c(6.4, 20.6, 3.2, 16.8, 3.2, 12.0)
            .c(3.2, 7.0, 7.1, 3.4, 12, 3.4)
            .z();
        a.path(paletteContour, fill: true, opacity: .10 + active * .12);
        a.path(paletteContour);
        a.dot(8.0, 9.6 - .4 * q, 1.25);
        a.dot(11.6, 7.6 - .5 * p, 1.25);
        a.dot(15.4, 9.4 - .4 * r, 1.25);
        a.dot(8.2, 14.2, 1.15);
      });
    case ArchiveSymbol.dot:
      a.circle(12, 12, 4.4 + .6 * p, fill: true);
    case ArchiveSymbol.shuffle:
      a.path(
        (s) => s
            .m(3.6, 7.5)
            .l(7.6, 7.5)
            .c(10.8, 7.5, 12.8, 16.5, 16.2, 16.5)
            .l(20.0 + .8 * p, 16.5),
      );
      a.poly([
        17.4 + .6 * p,
        14.0,
        20.2 + .8 * p,
        16.5,
        17.4 + .6 * p,
        19.0,
      ]);
      a.path(
        (s) => s
            .m(3.6, 16.5)
            .l(7.6, 16.5)
            .c(10.8, 16.5, 12.8, 7.5, 16.2, 7.5)
            .l(20.0 + .8 * q, 7.5),
      );
      a.poly([
        17.4 + .6 * q,
        5.0,
        20.2 + .8 * q,
        7.5,
        17.4 + .6 * q,
        10.0,
      ]);
    case ArchiveSymbol.sort:
      a.line(8.0, 4.8 - .9 * p, 8.0, 19.2);
      a.poly([5.0, 7.8 - .9 * p, 8.0, 4.8 - .9 * p, 11.0, 7.8 - .9 * p]);
      a.line(16.0, 4.8, 16.0, 19.2 + .9 * q);
      a.poly([
        13.0,
        16.2 + .9 * q,
        16.0,
        19.2 + .9 * q,
        19.0,
        16.2 + .9 * q,
      ]);
    case ArchiveSymbol.back:
    case ArchiveSymbol.up:
    case ArchiveSymbol.down:
    case ArchiveSymbol.arrowLeft:
    case ArchiveSymbol.arrowUp:
    case ArchiveSymbol.arrowDown:
    case ArchiveSymbol.external:
    case ArchiveSymbol.bookmarked:
    case ArchiveSymbol.locationFilled:
    case ArchiveSymbol.pause:
    case ArchiveSymbol.checkCircle:
    case ArchiveSymbol.selected:
    case ArchiveSymbol.eyeOff:
      throw StateError('Normalize variants before drawing');
  }
  return a;
}
