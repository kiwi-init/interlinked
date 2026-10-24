// The app icon: two linked glass frames, the mark's two squares woven together. The second frame
// passes in front of the first at the top right and behind it at the bottom left.
//   node script/app-icon/draw.mjs > script/app-icon/icon.svg
import { V, rot, rotAbout, slab, ringLoops, render, icon } from "./prism.mjs";

const b = 0.2, t = 0.1, o = 0.24;
const first = [-o, o, 0], second = [o, -o, 0];
// Tilting the second frame about its other diagonal lifts its top right and sinks its bottom left.
const tilt = rotAbout([1, -1, 0], second, 38);
const light = [[-0.5 + b * 0.9, 0.5 - b * 0.35], [0.5 - b * 0.9, 0.5 - b * 0.35]];

// The second frame in two halves, split corner to corner with mitred cuts, so the first can be drawn between them.
const lowerLeft = [[-0.5, 0.5], [-0.5, -0.5], [0.5, -0.5], [0.5 - b, -0.5 + b], [-0.5 + b, -0.5 + b], [-0.5 + b, 0.5 - b]];
const upperRight = [[-0.5, 0.5], [-0.5 + b, 0.5 - b], [0.5 - b, 0.5 - b], [0.5 - b, -0.5 + b], [0.5, -0.5], [0.5, 0.5]];

const A = slab({ loops: ringLoops(1, b), t, place: p => V.add(p, first), highlight: light });
const behind = slab({ loops: [lowerLeft], t, place: p => tilt(V.add(p, second)), skip: [2, 5] });
const inFront = slab({ loops: [upperRight], t, place: p => tilt(V.add(p, second)), skip: [0, 3], highlight: light });

process.stdout.write(icon(render([behind, A, inFront], { view: rot(-28, 22, 0) })));
