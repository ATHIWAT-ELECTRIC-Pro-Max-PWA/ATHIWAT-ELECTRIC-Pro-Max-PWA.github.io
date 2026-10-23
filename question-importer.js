(() => {
  const MAMMOTH_URL = 'https://cdn.jsdelivr.net/npm/mammoth@1.13.0/mammoth.browser.min.js';
  const PDFJS_URL = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@6.4.299/build/pdf.mjs';
  const PDFJS_WORKER_URL = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@6.4.299/build/pdf.worker.mjs';
  let mammothPromise;
  let pdfjsPromise;

  function loadScript(url, globalName) {
    if (window[globalName]) return Promise.resolve(window[globalName]);
    return new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = url;
      script.async = true;
      script.onload = () => window[globalName]
        ? resolve(window[globalName])
        : reject(new Error('โหลดตัวอ่านเอกสารไม่สำเร็จ กรุณาลองใหม่'));
      script.onerror = () => reject(new Error('เชื่อมต่อคลังตัวอ่านเอกสารไม่สำเร็จ กรุณาตรวจอินเทอร์เน็ต'));
      document.head.appendChild(script);
    });
  }

  async function loadMammoth() {
    mammothPromise ||= loadScript(MAMMOTH_URL, 'mammoth').catch(error => {
      mammothPromise = null;
      throw error;
    });
    return mammothPromise;
  }

  async function loadPdfJs() {
    pdfjsPromise ||= import(PDFJS_URL).then(pdfjs => {
      pdfjs.GlobalWorkerOptions.workerSrc = PDFJS_WORKER_URL;
      return pdfjs;
    }).catch(error => {
      pdfjsPromise = null;
      throw new Error('โหลดตัวอ่าน PDF ไม่สำเร็จ กรุณาตรวจอินเทอร์เน็ตแล้วลองใหม่');
    });
    return pdfjsPromise;
  }

  function normalizeText(value) {
    return String(value || '')
      .replace(/[\u200B-\u200D\uFEFF]/g, '')
      .replace(/\u00A0/g, ' ')
      .replace(/[๐-๙]/g, digit => String('๐๑๒๓๔๕๖๗๘๙'.indexOf(digit)))
      .replace(/\r\n?/g, '\n');
  }

  async function extractPdf(file) {
    const pdfjs = await loadPdfJs();
    const pdf = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
    if (pdf.numPages > 100) throw new Error('ไฟล์ PDF มีเกิน 100 หน้า กรุณาแบ่งไฟล์ก่อนนำเข้า');
    const pages = [];
    for (let pageNumber = 1; pageNumber <= pdf.numPages; pageNumber++) {
      const page = await pdf.getPage(pageNumber);
      const content = await page.getTextContent();
      const items = content.items
        .filter(item => typeof item.str === 'string' && item.str.trim())
        .map(item => ({
          text: item.str,
          x: Number(item.transform?.[4] || 0),
          y: Number(item.transform?.[5] || 0),
          width: Number(item.width || 0),
          height: Number(item.height || 0),
          hasEOL: Boolean(item.hasEOL)
        }))
        .sort((a, b) => b.y - a.y || a.x - b.x);
      const lines = [];
      let row = [];
      let rowY = null;
      const flush = () => {
        if (!row.length) return;
        row.sort((a, b) => a.x - b.x);
        let line = '';
        let right = null;
        for (const item of row) {
          if (right !== null && item.x - right > Math.max(2, item.height * 0.22)) line += ' ';
          line += item.text;
          right = item.x + item.width;
          if (item.hasEOL) {
            lines.push(line.trim());
            line = '';
            right = null;
          }
        }
        if (line.trim()) lines.push(line.trim());
        row = [];
        rowY = null;
      };
      for (const item of items) {
        if (rowY !== null && Math.abs(item.y - rowY) > 3) flush();
        if (rowY === null) rowY = item.y;
        row.push(item);
        rowY = row.reduce((sum, part) => sum + part.y, 0) / row.length;
      }
      flush();
      pages.push(lines.join('\n'));
      page.cleanup();
    }
    await pdf.destroy();
    const text = normalizeText(pages.join('\n\n'));
    if (!text.trim()) throw new Error('PDF นี้ไม่มีข้อความที่เลือกหรือคัดลอกได้ อาจเป็นไฟล์สแกนซึ่งยังไม่รองรับ OCR');
    return text;
  }

  async function extractFile(file) {
    if (!file) throw new Error('กรุณาเลือกไฟล์ .docx หรือ .pdf');
    if (file.size > 20 * 1024 * 1024) throw new Error('ไฟล์ใหญ่เกิน 20 MB กรุณาแบ่งไฟล์ก่อนนำเข้า');
    const extension = file.name.split('.').pop().toLowerCase();
    if (extension === 'docx') {
      const mammoth = await loadMammoth();
      const result = await mammoth.extractRawText({ arrayBuffer: await file.arrayBuffer() });
      return normalizeText(result.value);
    }
    if (extension === 'pdf') return extractPdf(file);
    throw new Error('รองรับเฉพาะไฟล์ .docx และ .pdf');
  }

  function normalizePart(value, fallback) {
    const match = String(value || '').match(/ภาค\s*([กขค])/);
    return match ? `ภาค ${match[1]}` : fallback;
  }

  function normalizeType(value, fallback) {
    const text = String(value || '').toLowerCase();
    return /กรณีพิเศษ|special/.test(text) ? 'special' : /รอบทั่วไป|ทั่วไป|general/.test(text) ? 'general' : fallback;
  }

  function normalizeAccess(value, fallback) {
    const text = String(value || '').toLowerCase();
    return /pro|โปร/.test(text) ? 'pro' : /พื้นฐาน|ฟรี|basic/.test(text) ? 'basic' : fallback;
  }

  function answerIndex(value) {
    const text = String(value || '').trim();
    const match = text.match(/^(?:ตัวเลือก\s*)?([กขคง]|[a-d]|[1-4])(?=$|[\s).,:：-])/i);
    if (!match) return null;
    const token = match[1].toLowerCase();
    const thai = 'กขคง'.indexOf(token);
    if (thai >= 0) return thai;
    if (/^[a-d]$/.test(token)) return token.charCodeAt(0) - 97;
    return Number(token) - 1;
  }

  function parseMetadata(line) {
    const match = line.match(/^\s*(ประเภท(?:การสอบ)?|ภาค|หมวดวิชา|วิชาเอก|วิชา|เรื่องย่อย|topic|ระดับ|สิทธิ์(?:การเข้าถึง)?|access)\s*[:：=]\s*(.*?)\s*$/i);
    if (!match) return null;
    const key = match[1].toLowerCase().replace(/\s/g, '');
    const value = match[2].trim();
    if (key.startsWith('ประเภท')) return ['type', normalizeType(value, null)];
    if (key === 'ภาค') return ['part', normalizePart(value, null)];
    if (['หมวดวิชา', 'วิชาเอก', 'วิชา'].includes(key)) return ['subject', value];
    if (key === 'เรื่องย่อย' || key === 'topic') return ['topic', value];
    if (key.startsWith('สิทธิ์') || key === 'ระดับ' || key === 'access') return ['access', normalizeAccess(value, null)];
    return null;
  }

  function parseQuestionText(source, defaults = {}) {
    const base = {
      type: defaults.type || 'general',
      part: defaults.part || 'ภาค ก',
      subject: String(defaults.subject || '').trim(),
      topic: String(defaults.topic || '').trim(),
      access: defaults.access || 'basic'
    };
    const globalTags = { ...base };
    const questions = [];
    let current = null;
    const lines = normalizeText(source).split('\n');
    const createQuestion = text => ({
      ...globalTags,
      text: String(text || '').trim(),
      choices: ['', '', '', ''],
      answer: null,
      explanation: '',
      keypoint: '',
      _choiceIndexes: new Set()
    });
    const finish = () => {
      if (current && (current.text || current._choiceIndexes.size)) {
        delete current._choiceIndexes;
        questions.push(current);
      }
      current = null;
    };
    const questionStart = line => {
      let m = line.match(/^\s*(?:ข้อ\s*(?:ที่\s*)?)?(\d{1,3})\s*[.)：:]?\s*(.*)$/i);
      if (!m) return null;
      const hasWord = /^\s*ข้อ/i.test(line);
      if (!hasWord && current && current._choiceIndexes.size < 4) return null;
      return m[2] || '';
    };

    for (const raw of lines) {
      const line = raw.trim().replace(/\s+/g, ' ');
      if (!line) continue;

      const qText = questionStart(line);
      if (qText !== null) {
        finish();
        current = createQuestion(qText);
        continue;
      }

      let match = line.match(/^\s*(?:คำตอบ|answer|ans)\s*[:：=]\s*(.*)$/i);
      if (match && current) {
        current.answer = answerIndex(match[1]);
        continue;
      }
      match = line.match(/^\s*เฉลย\s*[:：=]\s*(.*)$/i);
      if (match && current) {
        const index = answerIndex(match[1]);
        if (index !== null) {
          current.answer = index;
          current.explanation = match[1].replace(/^(?:ตัวเลือก\s*)?(?:[กขคง]|[a-d]|[1-4])(?=$|[\s).,:：-])\s*[).,:：-]?\s*/i, '').trim();
        } else {
          current.explanation = [current.explanation, match[1]].filter(Boolean).join(' ');
        }
        continue;
      }
      match = line.match(/^\s*(?:อธิบาย|คำอธิบาย|explanation)\s*[:：=]\s*(.*)$/i);
      if (match && current) {
        current.explanation = [current.explanation, match[1]].filter(Boolean).join(' ');
        continue;
      }
      match = line.match(/^\s*(?:key\s*point|keypoint|คีย์เวิร์ด|ประเด็นสำคัญ)\s*[:：=]\s*(.*)$/i);
      if (match && current) {
        current.keypoint = match[1].trim();
        continue;
      }

      const metadata = parseMetadata(line);
      if (metadata) {
        const [key, value] = metadata;
        if (value !== null) (current || globalTags)[key] = value;
        continue;
      }

      match = line.match(/^\s*(?:\(?([กขคง])\)?|\(?([a-d])\)?|\(?([1-4])\)?)\s*[.)、:：-]\s*(.+)$/i);
      if (match && current) {
        const letter = (match[1] || match[2] || '').toLowerCase();
        const numeric = match[3];
        const index = letter ? ('กขคง'.indexOf(letter) >= 0 ? 'กขคง'.indexOf(letter) : letter.charCodeAt(0) - 97) : Number(numeric) - 1;
        current.choices[index] = match[4].trim();
        current._choiceIndexes.add(index);
        continue;
      }

      if (!current) continue;
      if (current._choiceIndexes.size < 4) current.text = [current.text, line].filter(Boolean).join(' ');
      else current.explanation = [current.explanation, line].filter(Boolean).join(' ');
    }
    finish();
    return questions;
  }

  window.QuestionImporter = Object.freeze({ extractFile, parseQuestionText });
})();
