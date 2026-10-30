// 행사 포스터: RSVP 대표 이미지(4:3) · 인스타 피드(4:5) · 인스타 스토리(9:16)
// 행사 정보(rsvp_events)에서 문구를 채워 canvas로 그린다. 설정은 rsvp_events.poster에 저장.
(() => {
  const SIZES = {
    hero:  { w: 1600, h: 1200, label: 'RSVP 대표 4:3' },
    feed:  { w: 1080, h: 1350, label: '인스타 피드 4:5' },
    story: { w: 1080, h: 1920, label: '인스타 스토리 9:16' },
  };
  const STYLES = { bib: '레이스 번호표', sun: '붉은 원', speed: '속도선', photo: '사진' };
  const ACCENTS = [['#ff3d2e', 'MOVE RED'], ['#2b6cb0', 'RECOVER BLUE'], ['#f4f2ed', 'BONE']];
  const INK = '#0c0c0d', BONE = '#f4f2ed';
  const DISPLAY = '"Bebas Neue", "Pretendard", "Apple SD Gothic Neo", "Malgun Gothic", sans-serif';
  const BODY = '"Pretendard", "Apple SD Gothic Neo", "Malgun Gothic", sans-serif';
  const DOW_EN = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
  const p2 = n => String(n).padStart(2, '0');
  const kstParts = d => { const t = new Date(new Date(d).getTime() + 9 * 3600e3);
    return { y: t.getUTCFullYear(), m: p2(t.getUTCMonth() + 1), d: p2(t.getUTCDate()), dow: DOW_EN[t.getUTCDay()], hm: `${p2(t.getUTCHours())}:${p2(t.getUTCMinutes())}` }; };

  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  // ---------- 텍스트 ----------
  function wrap(ctx, text, maxW) {
    const out = [];
    for (const para of String(text).split('\n')) {
      let line = '';
      for (const word of para.split(/(\s+)/)) {
        const next = line + word;
        if (ctx.measureText(next.trim()).width <= maxW || !line.trim()) {
          if (ctx.measureText(next.trim()).width > maxW) {      // 공백 없는 긴 한글은 글자 단위로 자름
            for (const ch of word) { if (ctx.measureText((line + ch).trim()).width > maxW && line.trim()) { out.push(line.trim()); line = ''; } line += ch; }
          } else line = next;
        } else { out.push(line.trim()); line = word.trimStart(); }
      }
      out.push(line.trim());
    }
    return out;
  }
  // 상자 안에 들어가는 가장 큰 글자 크기를 찾는다
  function fit(ctx, text, font, maxW, maxH, maxSize, lh, maxLines) {
    for (let size = maxSize; size > 12; size -= Math.max(2, Math.round(size * 0.04))) {
      ctx.font = font(size);
      const lines = wrap(ctx, text, maxW);
      if (lines.length <= maxLines && lines.length * size * lh <= maxH) return { size, lines };
    }
    ctx.font = font(12); return { size: 12, lines: wrap(ctx, text, maxW).slice(0, maxLines) };
  }

  // ---------- 배경 ----------
  let grain;
  function grainPattern(ctx) {
    if (!grain) {
      grain = document.createElement('canvas'); grain.width = grain.height = 160;
      const g = grain.getContext('2d'), img = g.createImageData(160, 160);
      for (let i = 0; i < img.data.length; i += 4) { const v = Math.random() * 255; img.data[i] = img.data[i + 1] = img.data[i + 2] = v; img.data[i + 3] = 255; }
      g.putImageData(img, 0, 0);
    }
    return ctx.createPattern(grain, 'repeat');
  }
  function seeded(seed) { let s = seed % 2147483647 || 7; return () => (s = s * 16807 % 2147483647) / 2147483647; }

  function background(ctx, W, H, cfg, photo) {
    const A = cfg.accent;
    if (cfg.style === 'bib') {
      ctx.fillStyle = BONE; ctx.fillRect(0, 0, W, H);
      // 번호표 위·아래 스폰서 띠
      ctx.fillStyle = A; ctx.fillRect(0, 0, W, H * 0.085); ctx.fillRect(0, H * 0.915, W, H * 0.085);
      // 옷핀 구멍 4개
      const r = Math.min(W, H) * 0.014, ox = W * 0.045, oy = H * 0.125;
      ctx.fillStyle = 'rgba(12,12,13,.85)';
      for (const [x, y] of [[ox, oy], [W - ox, oy], [ox, H - oy], [W - ox, H - oy]]) { ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fill(); }
    } else if (cfg.style === 'sun') {
      ctx.fillStyle = INK; ctx.fillRect(0, 0, W, H);
      const R = Math.max(W, H) * 0.42;
      ctx.fillStyle = A; ctx.beginPath(); ctx.arc(W * 0.86, H * 0.2, R, 0, Math.PI * 2); ctx.fill();
    } else if (cfg.style === 'speed') {
      ctx.fillStyle = INK; ctx.fillRect(0, 0, W, H);
      const rnd = seeded(cfg.seed || 11);
      ctx.save(); ctx.translate(W / 2, H / 2); ctx.rotate(-0.22); ctx.translate(-W, -H);
      for (let i = 0; i < 46; i++) {
        const y = rnd() * H * 2, len = W * (0.4 + rnd() * 1.2), x = rnd() * W * 2;
        ctx.globalAlpha = 0.18 + rnd() * 0.7; ctx.fillStyle = A;
        ctx.fillRect(x, y, len, Math.max(2, H * (0.002 + rnd() * 0.012)));
      }
      ctx.restore(); ctx.globalAlpha = 1;
    } else {
      ctx.fillStyle = INK; ctx.fillRect(0, 0, W, H);
      if (photo) {
        const s = Math.max(W / photo.width, H / photo.height), pw = photo.width * s, ph = photo.height * s;
        ctx.save();
        if (cfg.tone !== 'color') ctx.filter = 'grayscale(1) contrast(1.15) brightness(.92)';
        ctx.drawImage(photo, (W - pw) / 2, (H - ph) / 2, pw, ph);
        ctx.restore();
        if (cfg.tone !== 'color') { ctx.globalCompositeOperation = 'multiply'; ctx.globalAlpha = 0.35; ctx.fillStyle = A; ctx.fillRect(0, 0, W, H); ctx.globalCompositeOperation = 'source-over'; ctx.globalAlpha = 1; }
      }
      const g = ctx.createLinearGradient(0, H * 0.35, 0, H);
      g.addColorStop(0, 'rgba(12,12,13,0)'); g.addColorStop(1, 'rgba(12,12,13,.88)');
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
      const t = ctx.createLinearGradient(0, 0, 0, H * 0.22);
      t.addColorStop(0, 'rgba(12,12,13,.55)'); t.addColorStop(1, 'rgba(12,12,13,0)');
      ctx.fillStyle = t; ctx.fillRect(0, 0, W, H * 0.22);
    }
    ctx.globalAlpha = 0.06; ctx.fillStyle = grainPattern(ctx); ctx.fillRect(0, 0, W, H); ctx.globalAlpha = 1;
  }

  // ---------- 포스터 ----------
  function info(ev, cfg) {
    const s = kstParts(ev.starts_at), e = ev.ends_at ? kstParts(ev.ends_at) : null;
    return {
      title: (cfg.headline || ev.title || '').trim(),
      sub: (cfg.sub ?? '').trim(),
      withLine: [ev.hosts, ev.partners].filter(Boolean).join(' × ') || 'S2:U',
      date: `${s.y}.${s.m}.${s.d} ${s.dow}`, bibNo: `${s.m}${s.d}`,
      time: e ? `${s.hm} – ${e.hm}` : s.hm,
      venue: ev.venue || '',
      fee: ev.is_paid ? `₩${(ev.fee || 0).toLocaleString('en-US')}` : 'FREE',
      seats: ev.capacity ? `${ev.capacity}명 한정` : '',
      sessions: (ev.sessions || []).map(x => x.label).filter(Boolean).slice(0, 3),
      link: `${location.origin}/rsvp/?e=${ev.slug}`,
      linkShort: `${location.host}/rsvp`,
    };
  }

  function drawQR(ctx, text, x, y, size, fg, bg) {
    if (!window.qrcode) return false;
    const q = window.qrcode(0, 'M'); q.addData(text); q.make();
    const n = q.getModuleCount(), pad = 2, cell = size / (n + pad * 2);
    ctx.fillStyle = bg; ctx.fillRect(x, y, size, size);
    ctx.fillStyle = fg;
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (q.isDark(r, c))
      ctx.fillRect(Math.floor(x + (c + pad) * cell), Math.floor(y + (r + pad) * cell), Math.ceil(cell), Math.ceil(cell));
    return true;
  }

  function draw(canvas, ev, cfg, sizeKey, photo) {
    const { w: W, h: H } = SIZES[sizeKey];
    canvas.width = W; canvas.height = H;
    const ctx = canvas.getContext('2d');
    const I = info(ev, cfg);
    const light = cfg.style === 'bib';
    const FG = light ? INK : BONE, DIM = light ? 'rgba(12,12,13,.62)' : 'rgba(244,242,237,.72)';
    const landscape = W > H, M = Math.round(Math.min(W, H) * 0.065);
    background(ctx, W, H, cfg, photo);
    ctx.textBaseline = 'alphabetic';

    // 상단: 로고 박스 + 주최/협업
    const top = cfg.style === 'bib' ? H * 0.085 + M * 0.9 : M;
    const ls = Math.round(Math.min(W, H) * 0.045);
    ctx.font = `${ls}px ${DISPLAY}`;
    const lw = ctx.measureText('S2:U').width + ls * 0.6;
    ctx.strokeStyle = FG; ctx.lineWidth = Math.max(2, ls * 0.07); ctx.strokeRect(M, top, lw, ls * 1.15);
    ctx.fillStyle = FG; ctx.fillText('S2:U', M + ls * 0.3, top + ls * 0.98);
    const ws = Math.round(ls * 0.42);
    ctx.font = `600 ${ws}px ${BODY}`; ctx.textAlign = 'right'; ctx.fillStyle = cfg.style === 'bib' ? INK : FG;
    ctx.fillText(I.withLine.toUpperCase(), W - M, top + ls * 0.78); ctx.textAlign = 'left';
    if (cfg.style === 'bib') {
      const band = fit(ctx, 'SUSTAIN TO YOU · RUN · MOVE · RECOVER', z => `700 ${z}px ${BODY}`, W - M * 2, H * 0.06, Math.round(H * 0.034), 1, 1);
      ctx.font = `700 ${band.size}px ${BODY}`; ctx.fillStyle = cfg.accent === BONE ? INK : BONE;
      ctx.fillText(band.lines[0], M, H * 0.0425 + band.size * 0.36);
    }

    // 하단 정보 영역 크기
    const rows = [['DATE', I.date], ['TIME', I.time], ['PLACE', I.venue], ['FEE', [I.fee, I.seats].filter(Boolean).join(' · ')]].filter(r => r[1]);
    const rs = Math.round(Math.min(W, H) * (landscape ? 0.03 : 0.034));
    const rowH = rs * 1.9;
    const qr = cfg.qr !== false;
    const qrSize = qr ? Math.round(Math.min(W, H) * (sizeKey === 'story' ? 0.24 : 0.2)) : 0;
    const bottomPad = cfg.style === 'bib' ? H * 0.085 + M * 0.7 : M;
    const footH = rs * 1.6;
    const infoH = Math.max(rows.length * rowH, qrSize + rs * 1.6);
    const infoTop = H - bottomPad - footH - infoH;

    // 번호표: 날짜를 큰 번호로
    let titleTop = top + ls * 1.15 + M * 0.8;
    if (cfg.style === 'bib') {
      const nb = fit(ctx, I.bibNo, s => `${s}px ${DISPLAY}`, W - M * 2, (infoTop - titleTop) * 0.42, Math.round(H * 0.3), 0.86, 1);
      ctx.font = `${nb.size}px ${DISPLAY}`; ctx.fillStyle = cfg.accent === BONE ? INK : cfg.accent;
      ctx.fillText(nb.lines[0], M - nb.size * 0.02, titleTop + nb.size * 0.82);
      titleTop += nb.size * 0.92;
    }

    // 메인 타이틀 (+ 한 줄 소개, 회차)
    const subLines = [I.sub, I.sessions.length && cfg.showSessions !== false ? I.sessions.join(' / ') : ''].filter(Boolean);
    const subSize = Math.round(Math.min(W, H) * 0.032);
    const subH = subLines.length ? subLines.length * subSize * 1.5 + M * 0.4 : 0;
    const titleBoxH = infoTop - titleTop - subH - M * 0.6;
    const titleW = landscape ? W * 0.72 : W - M * 2;
    const tf = fit(ctx, I.title.toUpperCase(), s => `${s}px ${DISPLAY}`, titleW, titleBoxH, Math.round(H * (landscape ? 0.2 : 0.16)), 0.9, 5);
    ctx.font = `${tf.size}px ${DISPLAY}`; ctx.fillStyle = FG;
    const tTotal = tf.lines.length * tf.size * 0.9;
    let ty = cfg.style === 'photo' || cfg.style === 'speed' ? titleTop + (titleBoxH - tTotal) : titleTop;
    tf.lines.forEach((l, i) => ctx.fillText(l, M - tf.size * 0.02, ty + tf.size * 0.8 + i * tf.size * 0.9));
    let sy = ty + tTotal + M * 0.5;
    ctx.font = `500 ${subSize}px ${BODY}`; ctx.fillStyle = DIM;
    for (const sl of subLines) { const w = wrap(ctx, sl, titleW)[0]; ctx.fillText(w, M, sy + subSize); sy += subSize * 1.5; }

    // 정보 표
    const tableW = W - M * 2 - (qr ? qrSize + M * 0.8 : 0);
    ctx.strokeStyle = light ? 'rgba(12,12,13,.25)' : 'rgba(244,242,237,.3)'; ctx.lineWidth = Math.max(1, rs * 0.06);
    rows.forEach(([k, v], i) => {
      const y = infoTop + i * rowH;
      ctx.beginPath(); ctx.moveTo(M, y); ctx.lineTo(M + tableW, y); ctx.stroke();
      ctx.font = `600 ${Math.round(rs * 0.62)}px ${BODY}`; ctx.fillStyle = DIM; ctx.fillText(k, M, y + rowH * 0.62);
      ctx.font = `700 ${rs}px ${BODY}`; ctx.fillStyle = FG;
      const kw = rs * 3.4; ctx.fillText(wrap(ctx, v, tableW - kw)[0], M + kw, y + rowH * 0.64);
    });
    if (rows.length) { const y = infoTop + rows.length * rowH; ctx.beginPath(); ctx.moveTo(M, y); ctx.lineTo(M + tableW, y); ctx.stroke(); }

    // QR + RSVP
    if (qr) {
      const qx = W - M - qrSize, qy = infoTop;
      drawQR(ctx, I.link, qx, qy, qrSize, INK, BONE);
      ctx.font = `${Math.round(rs * 1.15)}px ${DISPLAY}`; ctx.fillStyle = light ? INK : (cfg.accent === BONE ? BONE : cfg.accent);
      ctx.textAlign = 'center'; ctx.fillText('RSVP ↑', qx + qrSize / 2, qy + qrSize + rs * 1.25); ctx.textAlign = 'left';
    }

    // 하단 문구
    ctx.font = `600 ${Math.round(rs * 0.62)}px ${BODY}`; ctx.fillStyle = DIM;
    ctx.fillText(cfg.footer || `신청 ${I.linkShort} · 프로필 링크`, M, H - bottomPad);
    ctx.textAlign = 'right'; ctx.fillText('SUSTAIN TO YOU', W - M, H - bottomPad); ctx.textAlign = 'left';
  }

  // ---------- 화면 ----------
  async function mount(root, { ev, sb, toast, onSaved }) {
    const cfg = Object.assign({ style: 'sun', accent: '#ff3d2e', headline: '', sub: '', qr: true, showSessions: true, tone: 'duo', seed: 11 }, ev.poster || {});
    let size = 'feed', photo = null;
    root.innerHTML = `
      <div class="pst">
        <div class="pst-ctl">
          <label class="f">크기</label><div class="row" id="pSize">${Object.entries(SIZES).map(([k, v]) => `<button class="sm" data-size="${k}">${v.label}</button>`).join('')}</div>
          <label class="f">배경</label><div class="row" id="pStyle">${Object.entries(STYLES).map(([k, v]) => `<button class="sm" data-style="${k}">${v}</button>`).join('')}</div>
          <div id="pPhotoBox"><label class="f">사진 (사진 배경일 때)</label><input type="file" id="pPhoto" accept="image/*">
            <select id="pTone" style="margin-top:6px"><option value="duo">흑백 + 색 입히기</option><option value="color">원본 색</option></select></div>
          <label class="f">포인트 색</label><div class="row" id="pAccent">${ACCENTS.map(([c, n]) => `<button class="sm" data-accent="${c}" title="${n}"><span style="display:inline-block;width:12px;height:12px;border-radius:50%;background:${c};vertical-align:-1px;border:1px solid rgba(255,255,255,.3)"></span> ${n}</button>`).join('')}<input type="color" id="pColor" value="${esc(cfg.accent)}" style="width:44px;padding:2px;height:32px"></div>
          <label class="f">메인 타이틀 (비우면 행사명, 줄바꿈 유지)</label><textarea id="pHead" placeholder="${esc(ev.title)}">${esc(cfg.headline)}</textarea>
          <label class="f">한 줄 소개</label><input id="pSub" value="${esc(cfg.sub)}" maxlength="80">
          <label class="f">하단 문구</label><input id="pFoot" value="${esc(cfg.footer || '')}" placeholder="신청 ${esc(location.host)}/rsvp · 프로필 링크">
          <label class="f" style="display:flex;gap:8px;align-items:center"><input type="checkbox" id="pQr" style="width:auto" ${cfg.qr !== false ? 'checked' : ''}> RSVP QR 코드 넣기</label>
          <label class="f" style="display:flex;gap:8px;align-items:center"><input type="checkbox" id="pSess" style="width:auto" ${cfg.showSessions !== false ? 'checked' : ''}> 프로그램·회차 넣기</label>
          <div class="row" style="margin-top:8px"><button class="sm" id="pShuffle">속도선 다시 그리기</button></div>
          <p class="muted small" style="margin-top:14px">날짜·시간·장소·참가비·정원은 행사 설정에서 가져옵니다. 인스타그램 피드에서는 링크를 누를 수 없으니 QR과 '프로필 링크' 안내를 함께 넣었습니다.</p>
          <div class="row" style="margin-top:14px">
            <button class="pri" id="pHero">RSVP 대표 이미지로 적용</button>
            <button id="pDl">현재 크기 이미지 저장</button>
            <button id="pDlAll">3종 모두 저장</button>
            <button id="pSave">설정 저장</button>
          </div>
        </div>
        <div class="pst-view"><canvas id="pCanvas"></canvas><div class="muted small" id="pMeta" style="margin-top:6px"></div></div>
      </div>`;
    const $ = s => root.querySelector(s), canvas = $('#pCanvas');
    const mark = () => {
      root.querySelectorAll('[data-size]').forEach(b => b.classList.toggle('pri', b.dataset.size === size));
      root.querySelectorAll('[data-style]').forEach(b => b.classList.toggle('pri', b.dataset.style === cfg.style));
      $('#pPhotoBox').style.display = cfg.style === 'photo' ? '' : 'none';
      $('#pTone').value = cfg.tone;
    };
    const render = () => { mark(); draw(canvas, ev, cfg, size, photo); $('#pMeta').textContent = `${SIZES[size].w} × ${SIZES[size].h}px${cfg.style === 'photo' && !photo ? ' · 사진을 올려 주세요' : ''}`; };

    try { await Promise.all([document.fonts.load(`80px "Bebas Neue"`), document.fonts.load(`700 40px Pretendard`), document.fonts.load(`500 40px Pretendard`)]); } catch {}
    render();

    root.querySelectorAll('[data-size]').forEach(b => b.onclick = () => { size = b.dataset.size; render(); });
    root.querySelectorAll('[data-style]').forEach(b => b.onclick = () => { cfg.style = b.dataset.style; render(); });
    root.querySelectorAll('[data-accent]').forEach(b => b.onclick = () => { cfg.accent = b.dataset.accent; $('#pColor').value = cfg.accent; render(); });
    $('#pColor').oninput = e => { cfg.accent = e.target.value; render(); };
    $('#pHead').oninput = e => { cfg.headline = e.target.value; render(); };
    $('#pSub').oninput = e => { cfg.sub = e.target.value; render(); };
    $('#pFoot').oninput = e => { cfg.footer = e.target.value; render(); };
    $('#pQr').onchange = e => { cfg.qr = e.target.checked; render(); };
    $('#pSess').onchange = e => { cfg.showSessions = e.target.checked; render(); };
    $('#pTone').onchange = e => { cfg.tone = e.target.value; render(); };
    $('#pShuffle').onclick = () => { cfg.seed = Math.floor(Math.random() * 1e6) + 1; if (cfg.style !== 'speed') cfg.style = 'speed'; render(); };
    $('#pPhoto').onchange = e => {
      const f = e.target.files[0]; if (!f) return;
      const img = new Image(); img.onload = () => { photo = img; cfg.style = 'photo'; render(); URL.revokeObjectURL(img.src); };
      img.src = URL.createObjectURL(f);
    };

    const blobOf = key => new Promise(res => { const c = document.createElement('canvas'); draw(c, ev, cfg, key, photo); c.toBlob(res, 'image/jpeg', 0.92); });
    const download = async key => {
      const b = await blobOf(key), a = document.createElement('a');
      a.href = URL.createObjectURL(b); a.download = `${ev.slug}-${key}-${SIZES[key].w}x${SIZES[key].h}.jpg`;
      document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    };
    const saveCfg = async () => { const { error } = await sb.from('rsvp_events').update({ poster: cfg }).eq('id', ev.id); if (error) throw error; ev.poster = { ...cfg }; };

    $('#pDl').onclick = () => download(size);
    $('#pDlAll').onclick = async () => { for (const k of Object.keys(SIZES)) { await download(k); await new Promise(r => setTimeout(r, 400)); } };
    $('#pSave').onclick = async () => { try { await saveCfg(); toast('포스터 설정을 저장했습니다'); } catch (e) { toast('저장 실패: ' + e.message, 5000); } };
    $('#pHero').onclick = async () => {
      const btn = $('#pHero'); btn.disabled = true;
      try {
        const blob = await blobOf('hero');
        const path = `${ev.id}/hero-${Date.now()}.jpg`;
        const up = await sb.storage.from('rsvp-posters').upload(path, blob, { contentType: 'image/jpeg', upsert: false });
        if (up.error) throw up.error;
        const url = sb.storage.from('rsvp-posters').getPublicUrl(path).data.publicUrl;
        const { error } = await sb.from('rsvp_events').update({ hero_image: url, poster: cfg }).eq('id', ev.id);
        if (error) throw error;
        ev.hero_image = url; ev.poster = { ...cfg };
        toast('RSVP 페이지 대표 이미지로 적용했습니다'); onSaved && onSaved();
      } catch (e) { toast('적용 실패: ' + (e.message || e), 6000); }
      finally { btn.disabled = false; }
    };
  }

  window.S2Poster = { mount, draw, SIZES };
})();
