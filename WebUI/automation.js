import { t, language } from './i18n.js';

const days = [[1, 'Sun', 'Sunday'], [2, 'Mon', 'Monday'], [3, 'Tue', 'Tuesday'], [4, 'Wed', 'Wednesday'], [5, 'Thu', 'Thursday'], [6, 'Fri', 'Friday'], [7, 'Sat', 'Saturday']];
const modes = [['off', 'Off'], ['schedule', 'Time schedule'], ['appearance', 'Follow system appearance'], ['spaces', 'Follow desktop Space']];
const events = [['time', 'At a time'], ['sunrise', 'Sunrise'], ['sunset', 'Sunset']];
const configuration = (state, id) => state.automation?.displays?.[id] || { mode: 'off', rules: [], light: null, dark: null };
const targetValue = target => target ? JSON.stringify({ kind: target.kind, id: target.id }) : '';
const clock = minute => `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;

function targets(state) {
  return [
    ...(state.wallpapers || []).filter(item => item.supported).map(item => ({ kind: 'wallpaper', id: item.id, title: item.title })),
    ...(state.libraryOrganization?.plans || []).map(plan => ({ kind: 'playlist', id: plan.id, title: plan.name })),
  ];
}
function targetName(state, target) {
  if (!target) return t('Leave as it is');
  return targets(state).find(item => item.kind === target.kind && item.id === target.id)?.title || t('Unavailable');
}
function targetSelect(ctx, id, value, attributes, off, optional = false) {
  const { state, e } = ctx;
  const options = targets(state);
  const selected = typeof value === 'string' ? value : targetValue(value);
  const missing = selected && !options.some(item => targetValue(item) === selected);
  return `<select id="${e(id)}" ${attributes}${optional ? '' : ' required'}${off ? ' disabled' : ''}><option value=""${!selected ? ' selected' : ''}>${e(optional ? t('Leave as it is') : t('Choose a wallpaper or saved playlist'))}</option>${missing ? `<option value="${e(selected)}" selected>${e(t('Unavailable'))}</option>` : ''}${['wallpaper', 'playlist'].map(kind => `<optgroup label="${e(kind === 'wallpaper' ? t('Wallpapers') : t('Saved playlists'))}">${options.filter(item => item.kind === kind).map(item => `<option value="${e(targetValue(item))}"${targetValue(item) === selected ? ' selected' : ''}>${e(item.title)}</option>`).join('')}</optgroup>`).join('')}</select>`;
}
function ruleSummary(rule) {
  const repeat = rule.weekdays?.length === 7 ? t('Every day') : days.filter(([day]) => rule.weekdays?.includes(day)).map(([, short]) => t(short)).join(', ');
  const event = rule.event === 'time' ? clock(rule.minute) : t(rule.event === 'sunrise' ? 'Sunrise' : 'Sunset');
  const offset = rule.event !== 'time' && rule.offset ? t(rule.offset < 0 ? '{minutes} min before' : '{minutes} min after', { minutes: Math.abs(rule.offset) }) : '';
  return [repeat, event, offset].filter(Boolean).join(' · ');
}

function ruleEditor(ctx, displayID, off) {
  const { view, e, button } = ctx;
  const editor = view.automationEditor;
  if (editor?.displayID !== displayID) return '';
  const prefix = `automatic-${displayID}`;
  const field = (key, label, control) => `<label class="settings-auto-field" for="${e(`${prefix}-${key}`)}"><span>${e(label)}</span>${control}</label>`;
  const data = key => `id="${e(`${prefix}-${key}`)}" data-auto-field="${key}"`;
  const disabled = off ? ' disabled' : '';
  const timing = editor.event === 'time'
    ? field('time', t('Time'), `<input type="time" ${data('time')} value="${e(editor.time)}" required${disabled}>`)
    : field('offset', t('Offset in minutes'), `<input type="number" ${data('offset')} value="${e(editor.offset)}" min="-180" max="180" step="1" required${disabled}>`);
  return `<form class="settings-auto-editor" data-form="automation-rule" data-key="${e(prefix + '-editor')}" data-display-id="${e(displayID)}">`
    + field('event', t('When'), `<select ${data('event')}${disabled}>${events.map(([id, label]) => `<option value="${id}"${editor.event === id ? ' selected' : ''}>${e(t(label))}</option>`).join('')}</select>`)
    + timing
    + `<fieldset class="settings-auto-days"${editor.weekdaysError ? ` aria-describedby="${e(prefix)}-days-error"` : ''}><legend>${e(t('Repeat on'))}</legend><div>${days.map(([day, short, full]) => `<label><input type="checkbox" data-auto-day="${day}"${editor.weekdays.includes(day) ? ' checked' : ''}${disabled} aria-label="${e(t(full))}"><span>${e(t(short))}</span></label>`).join('')}</div><div class="settings-auto-shortcuts">${button(t('Weekdays'), 'autoDays', { value: 'weekdays' }, off)}${button(t('Weekends'), 'autoDays', { value: 'weekends' }, off)}${button(t('Every day'), 'autoDays', { value: 'all' }, off)}</div>${editor.weekdaysError ? `<p id="${e(prefix)}-days-error" class="settings-error" role="alert">${e(t('Choose at least one weekday.'))}</p>` : ''}</fieldset>`
    + `<div class="settings-auto-wide">${field('target', t('Switch to'), targetSelect(ctx, `${prefix}-target`, editor.target, 'data-auto-field="target"', off))}</div>`
    + (editor.event !== 'time' ? `<p class="settings-note settings-auto-wide">${e(t('Negative offsets run before the sun event; positive offsets run after it. Set your location below.'))}</p>` : '')
    + `<div class="settings-form-actions settings-auto-wide"><button type="submit" class="settings-button"${disabled}>${e(t('Save rule'))}</button>${button(t('Cancel'), 'autoRuleCancel', {}, off)}</div></form>`;
}

export function automationRows(ctx, display, off) {
  if (!ctx.state.automation) return '';
  const { e, row, disclosure, button, error, state } = ctx;
  const id = display.id;
  const value = configuration(state, id);
  const mode = `<select data-key="automation-mode-${e(id)}" data-auto-mode="${e(id)}" aria-label="${e(t('Automatic changes for {display}', { display: display.title }))}"${off ? ' disabled' : ''}>${modes.map(([key, label]) => `<option value="${key}"${value.mode === key ? ' selected' : ''}${key === 'spaces' && !value.spacesAvailable ? ' disabled' : ''}>${e(t(label))}</option>`).join('')}</select>`;
  const unavailableNote = value.mode !== 'spaces' && !value.spacesAvailable
    ? (value.spacesBlocked ? t('Turn off animated lock-screen wallpaper to use desktop Space choices.') : t('Desktop information is unavailable. Refresh Spaces or choose another automatic mode.')) : '';
  const rows = row(`automation-mode-${id}`, t('Automatic changes'), mode, [t('Manual choices stay until the next rule changes them.'), unavailableNote].filter(Boolean).join(' '));
  let body = '';
  if (value.mode === 'appearance') {
    body = ['light', 'dark'].map(key => row(`automation-${key}-${id}`, t(key === 'light' ? 'In light appearance' : 'In dark appearance'), targetSelect(ctx, `automation-${key}-${id}`, value[key], `data-auto-appearance="${key}" data-auto-display="${e(id)}" aria-label="${e(t(key === 'light' ? 'In light appearance' : 'In dark appearance'))}"`, off, true))).join('');
  } else if (value.mode === 'spaces') {
    const disabled = off || !value.spacesAvailable;
    body = `<p class="settings-note">${e(t('Experimental. Switching desktops reloads their chosen wallpaper or playlist and may briefly show the previous wallpaper. Full-screen app Spaces keep the last choice.'))}</p>`;
    if (!value.spacesAvailable) body += `<p class="settings-note" role="status">${e(value.spacesBlocked ? t('Turn off animated lock-screen wallpaper to use desktop Space choices.') : t('Desktop information is unavailable. Refresh Spaces or choose another automatic mode.'))}</p>`;
    body += (value.spaces || []).map(space => {
      const label = t(space.id === value.currentSpace ? 'Desktop {number} (current)' : 'Desktop {number}', { number: space.number });
      return row(`automation-space-${id}-${space.id}`, label,
        targetSelect(ctx, `automation-space-${id}-${space.id}`, space.target,
          `data-auto-space="${e(space.id)}" data-auto-display="${e(id)}" aria-label="${e(t('{label} for {display}', { label, display: display.title }))}"`, disabled, true));
    }).join('');
    body += (value.missingSpaces || []).map(space => row(`automation-missing-space-${id}-${space.id}`, t('Unavailable desktop'),
      button(t('Forget choice for {name}', { name: targetName(state, space.target) }), 'automationSpace', { displayID: id, spaceID: space.id, target: null }, off))).join('');
    body += `<p class="settings-note">${e(t('Desktop numbers follow their order on this display; choices follow the desktop when you reorder it. An empty choice keeps the current wallpaper.'))}</p>`;
  } else if (value.mode === 'schedule') {
    body = (value.rules || []).map(rule => `<div class="settings-rule settings-auto-rule" data-key="${e(`automation-rule-${id}-${rule.id}`)}"><span class="settings-rule-name"><strong>${e(targetName(state, rule.target))}</strong><span class="settings-note">${e(ruleSummary(rule))}</span></span>${button(t('Edit…'), 'autoRuleEdit', { displayID: id, id: rule.id }, off)}${button(t('Remove'), 'automationRuleRemove', { displayID: id, id: rule.id }, off)}</div>`).join('')
      + (!(value.rules || []).length ? `<p class="settings-empty">${e(t('No time rules yet. Add one to choose when this display changes.'))}</p>` : '')
      + button(t('Add time rule'), 'autoRuleNew', { displayID: id }, off || (value.rules || []).length >= 64)
      + ruleEditor(ctx, id, off)
      + `<p class="settings-note">${e(t('If times coincide, the later rule in this list wins. Missed changes wait until this display can play.'))}</p>`;
    if (value.next) body += `<p class="settings-note" role="status">${e(t('Next: {name} at {time}', { name: targetName(state, value.nextTarget), time: new Date(value.next).toLocaleString(language(), { weekday: 'short', hour: '2-digit', minute: '2-digit' }) }))}</p>`;
  }
  const focused = value.focused ? `<p class="settings-note" role="status">${e(t('A Focus filter is active for this display. Manual choices remain available.'))}</p>` : '';
  const failure = error(`automation-error-${id}`, value.error) + (value.error ? button(t('Retry automatic change'), 'automationRetry', { displayID: id }, off) : '');
  return disclosure(`automation-${id}`, t('Automatic wallpaper selection'), rows + body + focused + failure
    + `<p class="settings-note">${e(t('Choosing a wallpaper stops this display’s playlist. Choosing a saved playlist starts that plan. Focus choices temporarily override these rules.'))}</p>`
    + `<div class="settings-form-actions">${button(t('Refresh Spaces'), 'automationRefreshSpaces', {}, off)}${button(t('Open Focus Settings…'), 'openFocusSettings', {}, off)}</div>`, 'settings-disclosure-rows');
}

export function solarLocationGroup(ctx) {
  if (!ctx.state.automation) return '';
  const { state, view, e, group, button, busy } = ctx;
  const location = state.automation.location;
  const value = key => view.drafts.get(`solar-${key}`) ?? location?.[key] ?? '';
  const field = (key, label, min, max) => `<label class="settings-auto-field" for="solar-${key}"><span>${e(t(label))}</span><input id="solar-${key}" data-key="solar-${key}" name="${key}" type="number" inputmode="decimal" step="any" min="${min}" max="${max}" value="${e(value(key))}" required${busy ? ' disabled' : ''}></label>`;
  return group('solar-location', t('Sunrise and sunset'), ctx.error('automation-load-error', state.automation.error) + `<p class="settings-note">${e(t('Enter your coordinates. North and east are positive; south and west are negative. Times use your Mac’s time zone and are calculated locally.'))}</p><form class="settings-auto-editor" data-form="solar-location">${field('latitude', 'Latitude', -90, 90)}${field('longitude', 'Longitude', -180, 180)}<div class="settings-form-actions settings-auto-wide"><button type="submit" class="settings-button"${busy ? ' disabled' : ''}>${e(t('Save location'))}</button>${location ? button(t('Clear location'), 'automationClearLocation', {}, busy) : ''}</div></form><p class="settings-note">${e(t('Solar times are approximate. Near the poles, a day may have no sunrise or sunset.'))}</p>`);
}

export function automationClick(view, action, args, draw) {
  if (action === 'autoRuleNew' || action === 'autoRuleEdit') {
    const rule = configuration(view.state, args.displayID).rules?.find(rule => rule.id === args.id);
    view.automationEditor = { displayID: args.displayID, id: rule?.id, weekdays: [...(rule?.weekdays || [1, 2, 3, 4, 5, 6, 7])], event: rule?.event || 'time', time: clock(rule?.minute ?? 480), offset: String(rule?.offset ?? 0), target: targetValue(rule?.target) };
    draw();
    view.container.querySelector('form[data-form="automation-rule"] select')?.focus();
    return true;
  }
  if (action === 'autoRuleCancel') { view.automationFocus = view.automationEditor; view.automationEditor = null; draw(); restoreAutomationFocus(view); return true; }
  if (action === 'autoDays' && view.automationEditor) {
    view.automationEditor.weekdays = args.value === 'weekdays' ? [2, 3, 4, 5, 6] : args.value === 'weekends' ? [1, 7] : [1, 2, 3, 4, 5, 6, 7];
    view.automationEditor.weekdaysError = false;
    draw(); return true;
  }
  return false;
}

export function automationInput(view, input, draw) {
  const editor = view.automationEditor;
  if (!editor || !input.closest('form[data-form="automation-rule"]')) return false;
  if (input.dataset.autoDay) {
    const day = Number(input.dataset.autoDay);
    editor.weekdays = input.checked ? [...new Set([...editor.weekdays, day])] : editor.weekdays.filter(value => value !== day);
    if (editor.weekdaysError && editor.weekdays.length) { editor.weekdaysError = false; draw(); }
  } else if (input.dataset.autoField) {
    editor[input.dataset.autoField] = input.value;
    if (input.dataset.autoField === 'event') draw();
  } else { return false; }
  return true;
}

export async function automationChange(view, input, submit) {
  if (input.dataset.autoSpace) {
    await submit('automationSpace', { displayID: input.dataset.autoDisplay, spaceID: input.dataset.autoSpace, target: input.value ? JSON.parse(input.value) : null }); return true;
  }
  if (input.dataset.autoMode) {
    await submit('automationMode', { displayID: input.dataset.autoMode, value: input.value }); return true;
  }
  if (input.dataset.autoAppearance) {
    await submit('automationAppearance', { displayID: input.dataset.autoDisplay, key: input.dataset.autoAppearance, target: input.value ? JSON.parse(input.value) : null }); return true;
  }
  return false;
}

export async function automationSubmit(view, form, submit) {
  if (!['automation-rule', 'solar-location'].includes(form.dataset.form)) return false;
  if (!form.reportValidity()) return true;
  if (form.dataset.form === 'solar-location') {
    await submit('automationLocation', { latitude: form.elements.latitude.valueAsNumber, longitude: form.elements.longitude.valueAsNumber }, () => {
      view.drafts.delete('solar-latitude'); view.drafts.delete('solar-longitude');
    });
  } else {
    const editor = view.automationEditor;
    if (!editor) return true;
    if (!editor.weekdays.length) { editor.weekdaysError = true; return true; }
    const parts = editor.time.split(':').map(Number);
    const rule = { id: editor.id, weekdays: editor.weekdays, event: editor.event,
      minute: editor.event === 'time' ? parts[0] * 60 + parts[1] : 480,
      offset: editor.event === 'time' ? 0 : Number(editor.offset), target: JSON.parse(editor.target) };
    await submit('automationRuleSave', { displayID: editor.displayID, rule }, () => { view.automationFocus = editor; view.automationEditor = null; });
  }
  return true;
}

export function restoreAutomationFocus(view) {
  if (view.automationEditor?.weekdaysError) {
    view.container.querySelector('[data-form="automation-rule"] [data-auto-day]')?.focus();
    return;
  }
  const previous = view.automationFocus;
  if (!previous) return;
  view.automationFocus = null;
  const buttons = [...view.container.querySelectorAll('[data-action="autoRuleEdit"], [data-action="autoRuleNew"]')];
  const matching = buttons.filter(button => JSON.parse(button.dataset.args || '{}').displayID === previous.displayID);
  const exact = matching.find(button => JSON.parse(button.dataset.args || '{}').id === previous.id);
  (exact || matching.find(button => button.dataset.action === 'autoRuleNew'))?.focus();
}
