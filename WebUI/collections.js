// Local collections on Installed. The window sidebar lists them like albums and shows one at a
// time in the grid, the selection bar adds or removes the checked tiles, and a wallpaper's
// details tick the collections it belongs to. Native keeps the collections themselves
// (`libraryOrganization.collections` in the snapshot: id, name, wallpaperIDs) and validates
// every change; this module holds only what the page is doing right now: which collection is
// shown, a name being typed, and a Delete waiting for its second click.
import { t } from './i18n.js';

export function createCollections({ send, render, announce, escapeHTML, icon, button, keyAttr, checked, disabled, busy, selection }) {
  let state = null;
  let activeID = ''; // The collection the grid is filtered to; '' shows every wallpaper.
  let editor = null; // { mode: 'create' | 'rename', place: 'sidebar' | 'selection', collectionID, ids, name }
  let armed = ''; // The collection whose Delete has been pressed once.
  let notice = ''; // The last batch result, shown in the selection bar until the next change.
  let noticeTimer = 0;

  const available = () => Boolean(state?.libraryOrganization);
  const collections = () => (state?.libraryOrganization?.collections || []).filter(item => item && typeof item.id === 'string');
  const byID = (id) => collections().find(item => item.id === id) || null;
  const active = () => byID(activeID);
  const members = (item) => new Set(Array.isArray(item?.wallpaperIDs) ? item.wallpaperIDs : []);
  const pendingChange = () => ['collectionCreate', 'collectionRename', 'collectionDelete', 'collectionAdd', 'collectionRemove'].some(action => busy(action));

  // A collection that left the library (deleted here, or on another display's page) takes
  // the page's references to it along; the grid goes back to every wallpaper.
  function sync(snapshot) {
    state = snapshot;
    if (activeID && !byID(activeID)) activeID = '';
    if (editor?.collectionID && !byID(editor.collectionID)) editor = null;
    if (armed && !byID(armed)) armed = '';
  }
  const matches = (item) => !activeID || members(active()).has(item.id);
  const clearFilter = () => { activeID = ''; };
  function say(text) {
    notice = text;
    clearTimeout(noticeTimer);
    noticeTimer = setTimeout(() => { notice = ''; render(); }, 5000);
    announce(text);
  }

  function nameForm(id, place) {
    const rename = editor.mode === 'rename';
    return `<form class="inline-form" data-form="collectionName" data-cancel="collectionCancelEdit" ${keyAttr(`collection-editor-${place}`)}>`
      + `<label class="sr-only" for="${id}">${escapeHTML(t('Collection name'))}</label>`
      + `<input id="${id}" type="text" required maxlength="128" autocomplete="off" spellcheck="false" placeholder="${escapeHTML(t('Collection name'))}" value="${escapeHTML(editor.name)}" data-input="collectionName">`
      + `<div class="actions"><button type="submit" class="primary"${disabled(pendingChange())}>${escapeHTML(rename ? t('Save') : t('Create'))}</button>${button(t('Cancel'), 'collectionCancelEdit', {}, { className: 'quiet' })}</div></form>`;
  }
  function confirmDelete(item) {
    return `<div class="confirm-row" ${keyAttr(`collection-confirm-${item.id}`)}><p class="muted"><small>${escapeHTML(t('Delete “{name}”? Its wallpapers stay in your library.', { name: item.name }))}</small></p><div class="actions">${button(t('Delete'), 'collectionDelete', { collectionID: item.id }, { className: 'danger', disabled: pendingChange() })}${button(t('Cancel'), 'collectionDisarm', {}, { className: 'quiet' })}</div></div>`;
  }

  // The sidebar section: one item per collection with its size, the way to make a new one in
  // the heading, and the shown collection's own Rename and Delete beneath the list.
  function navSection({ navItem, current }) {
    if (!available()) return '';
    const shown = current ? active() : null;
    const sidebarEditor = editor?.place === 'sidebar' ? nameForm('collection-name', 'sidebar') : '';
    const items = collections().map(item => navItem({ page: 'installed', view: 'collection', collectionID: item.id, label: item.name, glyph: 'folder', count: members(item).size, current: shown?.id === item.id })).join('');
    const tools = shown && !sidebarEditor && armed !== shown.id
      ? `<div class="collection-tools">${button(t('Rename…'), 'collectionRenameBegin', { collectionID: shown.id }, { className: 'link', disabled: pendingChange() })}${button(t('Delete…'), 'collectionDeleteBegin', { collectionID: shown.id }, { className: 'link danger', disabled: pendingChange() })}</div>`
      : '';
    const confirm = shown && armed === shown.id && !sidebarEditor ? confirmDelete(shown) : '';
    const empty = !items && !sidebarEditor ? `<p class="muted"><small>${escapeHTML(t('Group wallpapers for browsing and for playlists.'))}</small></p>` : '';
    const add = button('', 'collectionNew', {}, { icon: 'plus', title: t('New collection…'), expanded: editor?.place === 'sidebar' && editor.mode === 'create', disabled: pendingChange() });
    return `<div class="sidebar-section" role="group" aria-label="${escapeHTML(t('Collections'))}" ${keyAttr('collections-section')}><div class="sidebar-heading"><span aria-hidden="true">${escapeHTML(t('Collections'))}</span>${add}</div>${items}${tools || confirm || sidebarEditor || empty ? `<div class="sidebar-tools">${empty}${tools}${confirm}${sidebarEditor}</div>` : ''}</div>`;
  }
  // Shows one collection in the grid; the sidebar follows.
  function show(id) { if (byID(id)) { activeID = id; armed = ''; } }

  // In the selection bar: add the checked tiles to a collection, or take them out of the one on
  // show. Choosing New collection… turns the picker into the name field right there.
  function selectionTools() {
    if (!available() || !selection.size) return '';
    if (editor?.place === 'selection') return nameForm('collection-name', 'selection');
    const current = active();
    const off = pendingChange();
    const picker = `<label class="sr-only" for="collection-picker">${escapeHTML(t('Add to collection'))}</label><select id="collection-picker" class="collection-picker" data-change="collectionPick" title="${escapeHTML(t('Adds the selected wallpapers to a collection'))}"${disabled(off)}><option value="">${escapeHTML(selection.size === 1 ? t('Add to collection…') : t('Add {count} to collection…', { count: selection.size.toLocaleString() }))}</option>${collections().map(item => `<option value="${escapeHTML(item.id)}">${escapeHTML(item.name)}</option>`).join('')}<option value="new">${escapeHTML(t('New collection…'))}</option></select>`;
    const remove = current ? button(t('Remove from “{name}”', { name: current.name }), 'collectionRemoveSelected', { collectionID: current.id }, { icon: 'listMinus', disabled: off || ![...selection].some(id => members(current).has(id)) }) : '';
    return `${picker}${remove}${notice ? `<span class="muted collection-notice" role="status">${escapeHTML(notice)}</span>` : ''}`;
  }

  // The details of one wallpaper: a box per collection, ticked where it belongs.
  function inspectorSection(item) {
    if (!available()) return '';
    const all = collections();
    const body = all.length
      ? `<div class="collection-membership">${all.map(collection => `<label class="check-label" ${keyAttr(`member-${collection.id}`)}><input type="checkbox" data-change="collectionMember" data-id="${escapeHTML(item.id)}" data-collection-id="${escapeHTML(collection.id)}"${checked(members(collection).has(item.id))}${disabled(pendingChange())}><span>${escapeHTML(collection.name)}</span></label>`).join('')}</div>`
      : `<p class="muted"><small>${escapeHTML(t('No collections yet. Collections group wallpapers for browsing and for playlists.'))}</small></p>`;
    return `<section class="inspector-section"><details${all.some(collection => members(collection).has(item.id)) ? ' open' : ''} ${keyAttr(`collections-${item.id}`)}><summary>${escapeHTML(t('Collections'))}${icon('chevronRight', 14)}</summary><div class="section-content">${body}${button(t('New collection…'), 'collectionNew', {}, { className: 'link', icon: 'plus', disabled: pendingChange() })}</div></details></section>`;
  }

  // The empty grid explains an empty collection rather than blaming the filters.
  function emptyState() {
    const current = active();
    if (!current || members(current).size) return null;
    return { description: t('“{name}” has no wallpapers yet. Select wallpapers and choose Add to collection.', { name: current.name }), actions: button(t('Show all wallpapers'), 'collectionShowAll') };
  }

  function focusEditor() { document.getElementById('collection-name')?.focus(); }
  function focusConfirm() { document.querySelector('[data-action="collectionDelete"]')?.focus(); }

  async function handleAction(action, data) {
    switch (action) {
      case 'collectionNew':
        editor = { mode: 'create', place: 'sidebar', name: '' };
        render(); focusEditor(); return true;
      case 'collectionRenameBegin': {
        const item = byID(data.collectionId);
        if (!item) return true;
        editor = { mode: 'rename', place: 'sidebar', collectionID: item.id, name: item.name };
        render(); focusEditor(); return true;
      }
      case 'collectionCancelEdit': editor = null; render(); return true;
      case 'collectionDeleteBegin': armed = data.collectionId; render(); focusConfirm(); return true;
      case 'collectionDisarm': armed = ''; render(); return true;
      case 'collectionDelete': {
        const item = byID(data.collectionId);
        armed = '';
        if (!item) { render(); return true; }
        await send('collectionDelete', { collectionID: item.id });
        say(t('Deleted “{name}”.', { name: item.name }));
        render(); return true;
      }
      case 'collectionRemoveSelected': {
        const item = byID(data.collectionId);
        const ids = [...selection];
        if (!item || !ids.length) return true;
        await send('collectionRemove', { collectionID: item.id, ids });
        say(t(ids.length === 1 ? 'Removed 1 wallpaper from “{name}”.' : 'Removed {count} wallpapers from “{name}”.', { count: ids.length.toLocaleString(), name: item.name }));
        render(); return true;
      }
      case 'collectionShowAll': activeID = ''; render(); return true;
      default: return false;
    }
  }

  async function handleChange(element) {
    const change = element.dataset.change;
    if (change === 'collectionPick') {
      const value = element.value;
      element.value = '';
      if (!value || !selection.size) return true;
      const ids = [...selection];
      if (value === 'new') { editor = { mode: 'create', place: 'selection', ids, name: '' }; render(); focusEditor(); return true; }
      const item = byID(value);
      if (!item) return true;
      await send('collectionAdd', { collectionID: item.id, ids });
      say(t(ids.length === 1 ? 'Added 1 wallpaper to “{name}”.' : 'Added {count} wallpapers to “{name}”.', { count: ids.length.toLocaleString(), name: item.name }));
      render(); return true;
    }
    if (change === 'collectionMember') {
      const item = byID(element.dataset.collectionId);
      if (!item) return true;
      await send(element.checked ? 'collectionAdd' : 'collectionRemove', { collectionID: item.id, ids: [element.dataset.id] });
      return true;
    }
    return false;
  }

  function handleInput(element) {
    if (element.dataset.input !== 'collectionName' || !editor) return false;
    editor.name = element.value;
    return true;
  }

  async function handleSubmit(form) {
    if (form.dataset.form !== 'collectionName' || !editor) return false;
    const name = String(form.querySelector('[data-input="collectionName"]')?.value || '').trim();
    if (!name) return true;
    const current = editor;
    if (current.mode === 'rename') {
      await send('collectionRename', { collectionID: current.collectionID, name });
      if (editor === current) editor = null;
      render(); return true;
    }
    const before = new Set(collections().map(item => item.id));
    const ids = Array.isArray(current.ids) ? current.ids : [];
    await send('collectionCreate', ids.length ? { name, ids } : { name });
    if (editor === current) editor = null;
    const created = collections().find(item => !before.has(item.id));
    if (created && current.place === 'sidebar') {
      activeID = created.id;
      if (state?.page !== 'installed') await send('navigate', { page: 'installed' });
    }
    if (created && ids.length) say(t(ids.length === 1 ? 'Added 1 wallpaper to “{name}”.' : 'Added {count} wallpapers to “{name}”.', { count: ids.length.toLocaleString(), name: created.name }));
    render(); return true;
  }

  return { sync, available, active, matches, clearFilter, show, navSection, selectionTools, inspectorSection, emptyState, handleAction, handleChange, handleInput, handleSubmit };
}
