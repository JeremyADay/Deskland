#!/usr/bin/env node
// Exercise the actual shared renderer field/transition code without a browser or system changes.
// The GL recorder checks the R16F data sent to textures; it performs no GPU readbacks.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const pages = process.argv[2] ? path.resolve(process.argv[2]) : path.join(root, 'prototype');
const CPU_TOLERANCE = 0.0002;
// The production uploads truncate to half-floats; these fixtures stay within 0.5 logical pixels.
const TEXTURE_TOLERANCE = 0.5;
let cases = 0, failures = 0;

function between(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a, `Renderer block missing: ${start} ... ${end}`);
  return source.slice(a, b);
}

function half(value) {
  const sign = value & 0x8000 ? -1 : 1;
  const exponent = (value >>> 10) & 31, mantissa = value & 1023;
  return sign * (exponent === 0 ? 2 ** -14 * mantissa / 1024
    : exponent === 31 ? (mantissa ? NaN : Infinity)
    : 2 ** (exponent - 15) * (1 + mantissa / 1024));
}

function maxDifference(a, b) {
  assert.equal(a.length, b.length, 'Field dimensions must agree');
  let worst = 0;
  for (let i = 0; i < a.length; i++) {
    assert.ok(Number.isFinite(a[i]) && Number.isFinite(b[i]), `Non-finite field at ${i}`);
    worst = Math.max(worst, Math.abs(a[i] - b[i]));
  }
  return worst;
}

function harness(file, { preview = false } = {}) {
  const source = fs.readFileSync(path.join(pages, file), 'utf8');
  const timing = between(source, 'const MORPH_MS =', '\n');
  const field = between(source, 'let fieldMs = 0;', 'const VS =');
  const textureStart = source.indexOf('const f32 =');
  const current = source.indexOf('const curS =', textureStart);
  assert.ok(textureStart >= 0 && current > textureStart, 'Transition block missing');
  const transition = source.slice(textureStart, source.indexOf('\n', current));
  const animation = between(source, 'const T0 = performance.now();', 'function draw(now)');
  const hosted = between(source, 'function startHostedMode()', '\n</script>');
  const cloudGeometry = file === 'meadow.html' ? [
    between(source, 'function hash2(x, y, k = 0)', 'function vnoise'),
    between(source, 'const rnd1 =', '\n'),
    'let flowT = 0;',
    between(source, 'const sstep =', '// 云里的圆在动'),
  ].join('\n') : '';
  let clock = 10000, bound = null, nextTexture = 0;
  let messageListener, drawCalls = 0;
  const textures = new Map();
  const gl = {
    TEXTURE_2D: 1, R16F: 2, RED: 3, HALF_FLOAT: 4, FLOAT: 5,
    TEXTURE_MIN_FILTER: 6, TEXTURE_MAG_FILTER: 7, LINEAR: 8,
    TEXTURE_WRAP_S: 9, TEXTURE_WRAP_T: 10, CLAMP_TO_EDGE: 11, UNPACK_ALIGNMENT: 12,
    createTexture() { const id = ++nextTexture; textures.set(id, {}); return id; },
    deleteTexture(id) { textures.delete(id); },
    bindTexture(_kind, id) { assert.ok(textures.has(id)); bound = id; },
    texParameteri() {},
    pixelStorei(key, value) { assert.equal(key, gl.UNPACK_ALIGNMENT); assert.equal(value, 1); },
    texImage2D(_kind, _level, _internal, width, height) {
      textures.set(bound, { width, height, values: new Float64Array(width * height) });
    },
    texSubImage2D(_kind, _level, x, y, width, height, _format, type, data) {
      const target = textures.get(bound);
      assert.equal(x, 0); assert.equal(y, 0);
      assert.equal(target.width, width); assert.equal(target.height, height);
      assert.equal(data.length, width * height);
      target.values = Float64Array.from(data, type === gl.HALF_FLOAT ? half : value => value);
    },
  };
  const context = vm.createContext({
    gl, performance: { now: () => clock }, console,
    W: 720, H: 440, STEP: 5, Gw: 145, Gh: 89,
    P: { sigma: file === 'flat.html' ? 85 : 72, warp: 0, edge: 10, adaptive: 1, cap30: 0 },
    seed: 1337,
    icons: [], NZ: { wx: new Float32Array(145 * 89), wy: new Float32Array(145 * 89) },
    PREVIEW: preview, SHOW_DIAGNOSTICS: false, iconsSeen: false, massList: null,
    document: { body: { classList: { add() {} }, appendChild() {} }, createElement() { return {}; } },
    parent: { postMessage(value) { assert.equal(JSON.parse(value).t, 'ready'); } },
    addEventListener(type, listener) { assert.equal(type, 'message'); messageListener = listener; },
    window: { devicePixelRatio: 1, chrome: { webview: {
      addEventListener(type, listener) { assert.equal(type, 'message'); messageListener = listener; },
      postMessage(value) { assert.equal(value, 'ready'); },
    } } },
    requestAnimationFrame() {}, draw() { drawCalls++; },
    stepKayaks() {}, stepBirds() {}, stepSkyClouds() {}, syncKayaks() {}, syncBirds() {}, drawGhosts() {},
  });
  vm.runInContext([timing, field, transition, cloudGeometry, animation, hosted].join('\n'), context, { filename: file });
  const run = code => vm.runInContext(code, context);
  run('allocField(); refresh();');
  const api = {
    icons(value) { context.icons = value.map(icon => ({ ...icon })); },
    commit(fromEmpty = false) { run(`commit(${fromEmpty});`); },
    present(progress) {
      const state = run('({morphT0,morphDur})');
      clock = state.morphT0 + state.morphDur * progress;
      // Use the renderer's actual curve and mode, including distinct intro/interactive easing.
      run('lastT = 0; frame(performance.now());');
    },
    snapshot() {
      const state = run('({FA,FB,fromI,toI,curMix,ftex})');
      const mix = state.curMix;
      const a = textures.get(state.ftex[state.fromI]).values;
      const b = textures.get(state.ftex[state.toI]).values;
      return {
        cpu: Float64Array.from(state.FA.s, (v, i) => v * (1 - mix) + state.FB.s[i] * mix),
        texture: Float64Array.from(a, (v, i) => v * (1 - mix) + b[i] * mix),
        mix,
      };
    },
    target() { return run('computeField(iconRects()).s'); },
    settled(icons) { api.icons(icons); run('refresh();'); api.present(1); },
    resize() {
      context.W = 810; context.H = 490; context.Gw = 163; context.Gh = 99;
      context.NZ = { wx: new Float32Array(163 * 99), wy: new Float32Array(163 * 99) };
      run('allocField(); refresh();');
    },
    liveTextureCount() { return textures.size; },
    startHosted() { run('startHostedMode();'); assert.equal(typeof messageListener, 'function'); },
    message(value) { messageListener({ data: JSON.stringify(value), source: context.parent }); },
    hostIcons(value) {
      api.message({ t: 'icons', vis: true, r: value.map(({ x, y, w, h }) => [x, y, x + w, y + h]) });
    },
    advance(milliseconds) { clock += milliseconds; run('frame(performance.now());'); },
    externalPause(value) { context.testPause = value; run('paused = testPause;'); },
    drawCalls() { return drawCalls; },
    isPaused() { return run('paused'); },
    cloudCircles() { return run('buildMassCircles()'); },
  };
  return api;
}

const A = [{ x: 95, y: 105, w: 64, h: 80 }];
const B = [{ x: 310, y: 175, w: 64, h: 80 }];
const C = [{ x: 550, y: 275, w: 64, h: 80 }];
const TWO = [...A, ...C];

function continuity(h, before, label) {
  // State must be coherent immediately, including when another event arrives before rAF.
  const immediate = h.snapshot();
  h.present(0);
  const firstFrame = h.snapshot();
  const cpu = maxDifference(before.cpu, firstFrame.cpu), texture = maxDifference(before.texture, firstFrame.texture);
  assert.ok(cpu <= CPU_TOLERANCE, `${label}: first-frame CPU field jumped ${cpu.toFixed(4)} px`);
  assert.ok(texture <= TEXTURE_TOLERANCE, `${label}: first-frame uploaded texture jumped ${texture.toFixed(4)} px`);
  const immediateCPU = maxDifference(before.cpu, immediate.cpu), immediateTexture = maxDifference(before.texture, immediate.texture);
  assert.ok(immediateCPU <= CPU_TOLERANCE, `${label}: between-event CPU field jumped ${immediateCPU.toFixed(4)} px`);
  assert.ok(immediateTexture <= TEXTURE_TOLERANCE, `${label}: between-event uploaded texture jumped ${immediateTexture.toFixed(4)} px`);
  assert.ok(maxDifference(firstFrame.cpu, firstFrame.texture) <= TEXTURE_TOLERANCE,
    `${label}: CPU collision/cloud field and uploaded terrain disagree`);
}

function finish(h) {
  h.present(1);
  const visible = h.snapshot();
  assert.ok(maxDifference(visible.cpu, h.target()) <= CPU_TOLERANCE, 'Transition must reach the latest target');
  assert.ok(maxDifference(visible.cpu, visible.texture) <= TEXTURE_TOLERANCE, 'Completed texture must match target');
  assert.equal(h.liveTextureCount(), 2, 'Interruptions must retain only two terrain textures');
}

const scenarios = {
  'reveal interrupted by hide'(h) {
    h.settled([]); h.icons(A); h.commit(true); h.present(0.32);
    const before = h.snapshot(); h.icons([]); h.commit(); continuity(h, before, 'reveal → hide'); finish(h);
  },
  'hide interrupted by reveal'(h) {
    h.settled(TWO); h.icons([]); h.commit(); h.present(0.43);
    const before = h.snapshot(); h.icons(TWO); h.commit(); continuity(h, before, 'hide → reveal'); finish(h);
  },
  'moving icon retargeted a second time'(h) {
    h.settled(A); h.icons(B); h.commit(); h.present(0.55);
    const before = h.snapshot(); h.icons(C); h.commit(); continuity(h, before, 'move → move'); finish(h);
  },
  'repeated hide/show and moves'(h) {
    h.settled(A);
    const layouts = [B, [], TWO, C, A, []];
    for (let i = 0; i < 36; i++) {
      const before = h.snapshot(); h.icons(layouts[i % layouts.length]); h.commit();
      continuity(h, before, `interruption ${i + 1}`); h.present(0.12 + (i % 6) * 0.13);
    }
    finish(h);
  },
  'two updates before the next frame'(h) {
    h.settled(A);
    const before = h.snapshot(); h.icons(B); h.commit(); h.icons(C); h.commit();
    continuity(h, before, 'back-to-back commits'); finish(h);
  },
  'completed transition starts from its reached state'(h) {
    h.settled(A); h.icons(B); h.commit(); h.present(1);
    const before = h.snapshot(); h.icons(C); h.commit(); continuity(h, before, 'completed → move'); finish(h);
  },
  'resize refresh replaces old grid cleanly'(h) {
    h.settled(A); h.icons(B); h.commit(); h.present(0.35); h.resize();
    const visible = h.snapshot();
    assert.equal(visible.mix, 1, 'Refresh must settle the newly sized field');
    assert.equal(visible.cpu.length, 163 * 99); finish(h);
  },
  'host pause freezes a rendered transition and resume excludes paused time'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(700);
    const before = h.snapshot();
    assert.ok(before.mix > 0 && before.mix < 1, 'Fixture must pause during a visible transition');
    h.message({ t: 'pause', v: true }); h.advance(5000);
    assert.equal(h.isPaused(), true);
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Pause must freeze the displayed field');
    h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Resume must not consume five seconds of paused time');
    const distance = maxDifference(h.snapshot().cpu, h.target());
    h.advance(200);
    assert.ok(maxDifference(h.snapshot().cpu, h.target()) < distance, 'Transition must continue advancing after resume');
  },
  'duplicate host pause and resume messages do not alter transition time'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(800);
    const before = h.snapshot();
    h.message({ t: 'pause', v: true }); h.advance(1000);
    h.message({ t: 'pause', v: true }); h.advance(4000);
    h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Duplicate pause must not replace the original pause time');
    h.advance(200);
    const resumed = h.snapshot();
    h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(resumed.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Duplicate resume must not shift the clock again');
  },
  'interactive transition resumes using its own easing curve'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600); h.hostIcons(B); h.advance(100);
    const before = h.snapshot();
    assert.ok(before.mix > 0 && before.mix < 1, 'Fixture must pause an interactive transition');
    h.message({ t: 'pause', v: true }); h.advance(5000);
    h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Interactive resume must invert the active easing curve');
    assert.ok(maxDifference(before.texture, h.snapshot().texture) <= TEXTURE_TOLERANCE);
    const distance = maxDifference(before.cpu, h.target()); h.advance(50);
    assert.ok(maxDifference(h.snapshot().cpu, h.target()) < distance, 'Interactive transition continues after resume');
  },
  'host resume preserves a pause established by another shared script'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(800);
    const before = h.snapshot();
    h.externalPause(true); h.advance(5000); h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Resume must use the visible field even without a host pause timestamp');
    assert.ok(maxDifference(before.texture, h.snapshot().texture) <= TEXTURE_TOLERANCE);
    assert.equal(h.isPaused(), false);
  },
  'resuming after a paused share snapshot does not rewind completed terrain'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(700);
    h.message({ t: 'pause', v: true }); h.advance(3000);
    // share.js temporarily resumes rendering to capture a settled image, then restores pause.
    h.externalPause(false); h.advance(400); h.externalPause(true);
    const captured = h.snapshot(); assert.equal(captured.mix, 1);
    h.advance(1000); h.message({ t: 'pause', v: false }); h.advance(0);
    assert.equal(h.snapshot().mix, 1, 'Completed captured terrain must stay completed after resume');
    assert.ok(maxDifference(captured.cpu, h.snapshot().cpu) <= CPU_TOLERANCE);
    assert.ok(maxDifference(captured.texture, h.snapshot().texture) <= TEXTURE_TOLERANCE);
  },
  'first known layout settles if paused before its first frame'(h) {
    h.startHosted(); h.advance(100); // A blank frame may render before the host knows icon positions.
    const draws = h.drawCalls(); h.hostIcons(A);
    assert.equal(h.drawCalls(), draws);
    h.message({ t: 'pause', v: true });
    assert.equal(h.isPaused(), true); assert.equal(h.snapshot().mix, 1);
    assert.ok(maxDifference(h.snapshot().cpu, h.target()) <= CPU_TOLERANCE);
    assert.ok(h.drawCalls() > draws, 'Covered startup must still paint its known layout');
  },
  'first known layout settles when icons arrive after the pause'(h) {
    h.startHosted(); h.message({ t: 'pause', v: true }); h.hostIcons(A);
    assert.equal(h.isPaused(), true); assert.equal(h.snapshot().mix, 1);
    assert.ok(maxDifference(h.snapshot().cpu, h.target()) <= CPU_TOLERANCE);
    assert.ok(h.drawCalls() > 0, 'Paused startup must paint its first icon message');
  },
  'icon updates while paused still clear and restore static terrain'(h) {
    h.startHosted(); h.hostIcons(TWO); h.advance(2600);
    const shown = h.snapshot();
    h.message({ t: 'pause', v: true }); h.hostIcons([]);
    assert.equal(h.snapshot().mix, 1); assert.equal(h.isPaused(), true);
    assert.ok(maxDifference(h.snapshot().cpu, h.target()) <= CPU_TOLERANCE);
    assert.ok(maxDifference(shown.cpu, h.snapshot().cpu) > 1, 'Hidden icons must remove their terrain');
    const draws = h.drawCalls(); h.hostIcons(TWO);
    assert.ok(maxDifference(h.snapshot().cpu, shown.cpu) <= CPU_TOLERANCE, 'Revealed icons restore the settled layout');
    assert.ok(h.drawCalls() > draws, 'Paused layout changes still need a static redraw');
    h.advance(5000); h.message({ t: 'pause', v: false }); h.advance(0);
    assert.ok(maxDifference(h.snapshot().cpu, shown.cpu) <= CPU_TOLERANCE, 'Resuming a settled paused update must not revive its transition');
  },
};

const previewScenarios = {
  'preview host retargets an interactive move without a jump'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600); h.hostIcons(B); h.advance(100);
    const before = h.snapshot(); h.hostIcons([]); continuity(h, before, 'preview move → hide'); finish(h);
  },
  'preview host ignores wallpaper pause messages'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600); h.hostIcons(B); h.advance(100);
    const before = h.snapshot(); h.message({ t: 'pause', v: true });
    assert.equal(h.isPaused(), false); h.advance(50);
    assert.ok(h.snapshot().mix > before.mix, 'Preview animation continues after a host pause message');
  },
};

const meadowResponseScenarios = {
  'interactive cloud reveal becomes visible within 400ms and settles within 500ms'(h) {
    h.startHosted(); h.hostIcons([]); h.advance(2600); h.hostIcons(A);
    let visibleAt = null, settledAt = null;
    for (let elapsed = 33; elapsed <= 660; elapsed += 33) {
      h.advance(33);
      const circles = h.cloudCircles();
      for (let i = 2; i < circles.length; i += 4) {
        if (circles[i] >= 2 && visibleAt === null) visibleAt = elapsed;
      }
      if (h.snapshot().mix === 1 && settledAt === null) settledAt = elapsed;
    }
    assert.ok(visibleAt !== null && visibleAt <= 400, `First cloud radius ≥2px appeared at ${visibleAt}ms`);
    assert.ok(settledAt !== null && settledAt <= 500, `Cloud transition settled at ${settledAt}ms`);
    console.log(`  Meadow reveal fixture (seed 1337, warp 0): visible ${visibleAt}ms; settled ${settledAt}ms`);
  },
  'moving an existing cloud changes its geometry on the first 33ms frame'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600);
    const before = h.cloudCircles(); assert.ok(before.length > 0, 'Fixture needs visible icon clouds');
    h.hostIcons(B); h.advance(33);
    const after = h.cloudCircles(), radii = new Map();
    for (let i = 0; i < after.length; i += 4) radii.set(`${after[i]},${after[i + 1]}`, after[i + 2]);
    let delta = 0;
    for (let i = 0; i < before.length; i += 4) {
      delta = Math.max(delta, Math.abs(before[i + 2] - (radii.get(`${before[i]},${before[i + 1]}`) ?? 0)));
    }
    assert.ok(delta >= 1, `Existing cloud radius changed by only ${delta.toFixed(4)}px in its first frame`);
    console.log(`  Meadow move fixture (seed 1337, warp 0): first-frame radius change ${delta.toFixed(2)}px`);
  },
  'hiding clouds remains visible on the first frame and clears within 200ms'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600); h.hostIcons([]); h.advance(33);
    const firstFrame = h.cloudCircles();
    assert.ok(firstFrame.some((value, i) => i % 4 === 2 && value >= 2), 'Clouds must shrink over frames instead of vanishing in one frame');
    h.advance(167);
    assert.equal(h.cloudCircles().length, 0, 'Hidden icon clouds should clear within 200ms');
  },
  'intro retains its gradual 2600ms quadratic timing'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(300);
    assert.ok(Math.abs(h.snapshot().mix - 2 * (300 / 2600) ** 2) < 1e-9, 'Intro should be about 3% revealed at 300ms');
    h.advance(300); assert.ok(h.snapshot().mix < 1, 'Intro must not finish on interactive timing');
    h.advance(50);
    assert.ok(Math.abs(h.snapshot().mix - 0.125) < 1e-9, 'Intro quarter-time should retain quadratic easing');
    h.advance(650);
    assert.ok(Math.abs(h.snapshot().mix - 0.5) < 1e-9, 'Intro midpoint should stay at half mix');
    h.advance(1300); assert.equal(h.snapshot().mix, 1);
  },
  'interrupting the intro switches smoothly to interactive response'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(650);
    const before = h.snapshot(); h.hostIcons(B); continuity(h, before, 'intro → interactive move');
    h.advance(300);
    assert.ok(h.snapshot().mix >= 0.7, 'New icon target should use the responsive interactive curve');
    h.advance(300); assert.equal(h.snapshot().mix, 1, 'Retargeted intro should finish on interactive timing');
  },
  'first frame timestamp before commit does not extrapolate the field'(h) {
    h.startHosted(); h.hostIcons(A); h.advance(2600); h.hostIcons(B);
    const before = h.snapshot();
    h.advance(-5);
    assert.equal(h.snapshot().mix, 0, 'An earlier rAF timestamp must clamp to the start');
    assert.ok(maxDifference(before.cpu, h.snapshot().cpu) <= CPU_TOLERANCE, 'Stale timestamp must preserve the visible field');
    h.advance(5); assert.equal(h.snapshot().mix, 0);
    h.advance(33); assert.ok(h.snapshot().mix > 0, 'Future timestamps must advance normally');
  },
};

for (const [name, file] of [['Beach', 'flat.html'], ['Meadow', 'meadow.html']]) {
  for (const [scenario, test] of Object.entries(scenarios)) {
    cases++;
    try { test(harness(file)); console.log(`PASS ${name}: ${scenario}`); }
    catch (error) { failures++; console.error(`FAIL ${name}: ${scenario}\n  ${error.message}`); }
  }
  for (const [scenario, test] of Object.entries(previewScenarios)) {
    cases++;
    try { test(harness(file, { preview: true })); console.log(`PASS ${name}: ${scenario}`); }
    catch (error) { failures++; console.error(`FAIL ${name}: ${scenario}\n  ${error.message}`); }
  }
  if (file === 'meadow.html') for (const [scenario, test] of Object.entries(meadowResponseScenarios)) {
    cases++;
    try { test(harness(file)); console.log(`PASS ${name}: ${scenario}`); }
    catch (error) { failures++; console.error(`FAIL ${name}: ${scenario}\n  ${error.message}`); }
  }
}
console.log(`Terrain transitions: ${cases - failures}/${cases} scenarios passed`);
if (failures) process.exitCode = 1;
