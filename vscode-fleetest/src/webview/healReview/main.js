// Webview script for the self-heal review panel (host: src/healReviewPanel.ts).
// Bundled by esbuild to media/healReview/main.js.
// Initial data (localized text + items) comes from the JSON block #heal-review-data that
// renderHtml() writes; message types (addItems/busy/applyResult/applyError, apply/close) pair with
// HealToWebviewMessage / HealFromWebviewMessage in healReviewPanel.ts.

import {
  buildPreviewAfterLine,
  computeNewComment,
  isValidComment,
  isValidSelector,
} from '../../healModel';

(function () {
  const vscode = acquireVsCodeApi();

  // No default right-click menu (Cut/Copy/Paste) except in text inputs (selector/comment edits need paste).
  // Same rule on every screen of the extension (pair: the same listener in src/webview/monitor/main.js).
  document.addEventListener('contextmenu', (event) => {
    const target = event.target;
    const editable = target instanceof HTMLTextAreaElement
      || (target instanceof HTMLInputElement && !['checkbox', 'radio', 'button', 'range'].includes(target.type))
      || (target instanceof HTMLElement && target.isContentEditable);
    if (!editable) {
      event.preventDefault();
    }
  });
  const rowsEl = document.getElementById('rows');
  const emptyEl = document.getElementById('empty');
  const btnApply = document.getElementById('btn-apply');
  const btnClose = document.getElementById('btn-close');
  const busyLabel = document.getElementById('busy-label');
  const errorArea = document.getElementById('error-area');

  const initial = JSON.parse(document.getElementById('heal-review-data').textContent);
  // Already localized on the extension host. applyButtonTemplate keeps the literal '{count}' token.
  const TXT = initial.txt;

  // id -> row handle (DOM element + item data)
  const rows = new Map();
  let busy = false;

  function createRow(item) {
    const row = document.createElement('div');
    row.className = 'row';

    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = !item.unavailable;
    checkbox.disabled = item.unavailable;

    const body = document.createElement('div');
    body.className = 'row-body';

    const scenarioEl = document.createElement('div');
    scenarioEl.className = 'scenario-id';
    scenarioEl.textContent = item.scenarioID;

    const locationEl = document.createElement('div');
    locationEl.className = 'location';
    locationEl.textContent = item.file + ':' + item.line;

    const beforeField = document.createElement('div');
    beforeField.className = 'field';
    const beforeLabel = document.createElement('span');
    beforeLabel.className = 'label';
    beforeLabel.textContent = TXT.fieldBefore;
    const beforeCode = document.createElement('code');
    beforeCode.textContent = item.oldSelector;
    beforeField.append(beforeLabel, beforeCode);

    const afterField = document.createElement('div');
    afterField.className = 'field';
    const afterLabel = document.createElement('span');
    afterLabel.className = 'label';
    afterLabel.textContent = TXT.fieldAfter;
    const selectorInput = document.createElement('input');
    selectorInput.type = 'text';
    selectorInput.value = item.newSelector;
    afterField.append(afterLabel, selectorInput);

    const selectorWarn = document.createElement('div');
    selectorWarn.className = 'warn';
    selectorWarn.textContent = TXT.selectorWarn;
    selectorWarn.style.display = 'none';

    const commentField = document.createElement('div');
    commentField.className = 'field';
    const commentLabel = document.createElement('span');
    commentLabel.className = 'label';
    commentLabel.textContent = TXT.fieldComment;
    const commentInput = document.createElement('input');
    commentInput.type = 'text';
    commentInput.value = item.originalComment || '';
    commentField.append(commentLabel, commentInput);

    const commentWarn = document.createElement('div');
    commentWarn.className = 'warn';
    commentWarn.textContent = TXT.commentWarn;
    commentWarn.style.display = 'none';

    const preview = document.createElement('div');
    preview.className = 'preview';

    const unavailableWarn = document.createElement('div');
    unavailableWarn.className = 'warn';
    unavailableWarn.textContent = TXT.unavailableWarn;

    const messageEl = document.createElement('div');
    messageEl.className = 'message';
    messageEl.textContent = item.message || '';

    body.append(scenarioEl, locationEl, beforeField, afterField, selectorWarn, commentField, commentWarn);
    if (item.unavailable) {
      body.appendChild(unavailableWarn);
    } else {
      body.appendChild(preview);
    }
    if (item.message) {
      body.appendChild(messageEl);
    }

    row.append(checkbox, body);
    rowsEl.appendChild(row);

    const handle = { item, row, checkbox, selectorInput, commentInput, selectorWarn, commentWarn, preview };
    rows.set(item.id, handle);

    function revalidate() {
      const selectorValid = isValidSelector(selectorInput.value);
      const commentValid = isValidComment(commentInput.value);
      selectorWarn.style.display = selectorValid ? 'none' : 'block';
      commentWarn.style.display = commentValid ? 'none' : 'block';
      if ((!selectorValid || !commentValid) && checkbox.checked) {
        checkbox.checked = false;
      }
      checkbox.disabled = item.unavailable || !selectorValid || !commentValid;
      if (!item.unavailable && selectorValid) {
        const after = buildPreviewAfterLine(
          item.originalLine, item.oldSelector, selectorInput.value,
          item.originalComment, commentValid ? commentInput.value : (item.originalComment || ''),
        );
        preview.textContent = '';
        const delLine = document.createElement('div');
        delLine.className = 'del';
        delLine.textContent = '- ' + item.originalLine;
        const addLine = document.createElement('div');
        addLine.className = 'add';
        addLine.textContent = '+ ' + after;
        preview.append(delLine, addLine);
      }
      updateApplyButton();
    }

    selectorInput.addEventListener('input', revalidate);
    commentInput.addEventListener('input', revalidate);
    checkbox.addEventListener('change', updateApplyButton);
    revalidate();

    return handle;
  }

  function addItems(items) {
    for (const item of items) {
      if (!rows.has(item.id)) {
        createRow(item);
      }
    }
    updateEmptyState();
    updateApplyButton();
  }

  function updateEmptyState() {
    const visible = [...rows.values()].some((h) => h.row.style.display !== 'none');
    emptyEl.style.display = visible ? 'none' : 'block';
  }

  function updateApplyButton() {
    const checkedCount = [...rows.values()].filter((h) => !h.row.classList.contains('applied') && h.checkbox.checked).length;
    btnApply.textContent = TXT.applyButtonTemplate.replace('{count}', String(checkedCount));
    btnApply.disabled = busy || checkedCount === 0;
    btnClose.disabled = busy;
  }

  function setBusy(value) {
    busy = value;
    busyLabel.style.display = busy ? 'inline' : 'none';
    updateApplyButton();
  }

  function collectFixes() {
    const fixes = [];
    for (const handle of rows.values()) {
      if (handle.row.classList.contains('applied') || !handle.checkbox.checked) {
        continue;
      }
      const selector = handle.selectorInput.value;
      const comment = handle.commentInput.value;
      if (!isValidSelector(selector) || !isValidComment(comment)) {
        continue;
      }
      fixes.push({
        scenarioID: handle.item.scenarioID,
        file: handle.item.file,
        line: handle.item.line,
        oldSelector: handle.item.oldSelector,
        newSelector: selector,
        newComment: computeNewComment(handle.item.originalComment, comment),
      });
    }
    return fixes;
  }

  function showError(text) {
    errorArea.textContent = text;
    errorArea.style.display = text ? 'block' : 'none';
  }

  btnApply.addEventListener('click', () => {
    const fixes = collectFixes();
    if (fixes.length === 0) { return; }
    showError('');
    vscode.postMessage({ type: 'apply', fixes });
  });
  btnClose.addEventListener('click', () => {
    vscode.postMessage({ type: 'close' });
  });

  window.addEventListener('message', (event) => {
    const message = event.data;
    if (!message || typeof message.type !== 'string') { return; }
    switch (message.type) {
      case 'addItems':
        addItems(message.items);
        break;
      case 'busy':
        setBusy(!!message.busy);
        break;
      case 'applyResult': {
        for (const id of message.appliedIds) {
          const handle = rows.get(id);
          if (handle) {
            handle.row.classList.add('applied');
            handle.row.style.display = 'none';
          }
        }
        if (message.failures.length > 0) {
          const lines = message.failures.map((f) => {
            const handle = rows.get(f.id);
            const label = handle ? handle.item.scenarioID + '(' + handle.item.file + ':' + handle.item.line + ')' : f.id;
            return label + ': ' + f.message;
          });
          showError(lines.join('\n'));
        } else {
          showError('');
        }
        updateEmptyState();
        updateApplyButton();
        break;
      }
      case 'applyError':
        showError(message.message);
        break;
      default:
        break;
    }
  });

  addItems(initial.items);
})();
