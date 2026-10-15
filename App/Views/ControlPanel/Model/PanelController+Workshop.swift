import Foundation

/// Steam Workshop (Discover): browsing, sources, paging, selection, the Steam Community sign-in
/// that subscriptions need, update checks and reinstalling.
///
/// Browsing is never queued behind a renderer command and leaves an older banner showing (the
/// catalog's `E`), so Discover stays usable while a wallpaper applies. Requests that change the
/// library's content (updates, reinstalling) wait their turn with the other commands.
extension PanelController {
  /// The most characters a text the panel sends may have, as the web panel refused longer ones.
  private static var maxTextLength: Int { 65_536 }

  // MARK: State

  /// The page's list-level state: tiles, source, paging, the last load's outcome.
  var workshopBrowse: WorkshopBrowseState { WorkshopBrowseState(workshop) }

  /// Everything one Discover tile wears. A tile calls this itself, so a progress tick re-renders
  /// only the tile whose job moved.
  func workshopTile(for item: WorkshopItem) -> WorkshopTile {
    WorkshopTile(
      item: item, isInstalled: mediaLibraryContains(item.id),
      isFavorite: favoriteIDs.contains(item.id),
      download: item.isCollection
        ? nil
        : TileDownloadState.workshop(
          title: item.title, request: downloadRequestRow(for: item.id),
          job: steamDownloadRow(for: item.id), setupIsReady: steamSetup.isReady))
  }

  /// What the Discover inspector offers for the item's download, and what it says about it.
  func workshopItemDownload(for item: WorkshopItem) -> WorkshopItemDownload {
    let target = mediaApplyTarget
    return WorkshopItemDownload.make(
      item: item, request: downloadRequestRow(for: item.id), job: steamDownloadRow(for: item.id),
      isInstalled: mediaLibraryContains(item.id), canApplyToTarget: target.canShowWallpaper,
      applyNote: workshopApplyNote(for: item.id))
  }

  /// The Workshop's newer version of an installed wallpaper, when its author changed it since it
  /// was installed. This is what marks the wallpaper in Installed and the sidebar.
  func workshopUpdate(for id: String) -> WorkshopItem? { workshop.updates.available[id] }

  /// What the inspector says about an installed wallpaper's update, or nil when it has none and
  /// none is downloading.
  func workshopUpdateNotice(for id: String) -> WorkshopUpdateNotice? {
    WorkshopUpdateNotice.make(
      update: workshopUpdate(for: id), request: downloadRequestRow(for: id),
      job: steamDownloadRow(for: id))
  }

  /// Why a wallpaper that arrived through **Download and apply** was left alone ("you chose another
  /// wallpaper", "the download took more than an hour"), for the inspector of the installed
  /// wallpaper too; nil when there is none or the target display shows it by now.
  func workshopApplyNote(for id: String) -> String? {
    guard mediaApplyTarget.wallpaperID != id, let note = workshop.applyNotes[id], !note.isEmpty
    else { return nil }
    return note
  }

  /// What double-clicking a Discover tile does: open a collection; apply a wallpaper that is in the
  /// library and that the target display can show (else select it); select one that is downloading;
  /// reopen the dialog of one waiting for a prerequisite; otherwise download it.
  ///
  /// Every tile asks it for VoiceOver's name of the action, so the library is looked through only
  /// for an item the kept index (`mediaLibraryContains`) says is in it.
  func workshopDoubleClick(for item: WorkshopItem) -> WorkshopTileDoubleClick {
    if item.isCollection { return .openCollection }
    if mediaLibraryContains(item.id),
      let installed = store.librarySnapshot.wallpapers.first(where: { $0.id == item.id })
    {
      return installed.kind != .unknown && mediaApplyTarget.canShowWallpaper ? .apply : .select
    }
    if steamDownloadRow(for: item.id)?.isPending == true { return .select }
    return downloadRequestRow(for: item.id) != nil ? .continueSetup : .requestDownload
  }

  /// The check for updates of installed Workshop wallpapers.
  var workshopUpdates: WorkshopUpdatesState { WorkshopUpdatesState(workshop.updates) }

  // MARK: Browsing

  /// Searches Steam: stores the query and starts it afresh from the first page. A repeat while a
  /// search is pending should use `.latestWins`, so the newest search is the one on show.
  ///
  /// `kind` is every type unless a caller narrows it; the panel narrows by tags alone. The limits
  /// are those the controls keep: 32 required and 64 excluded tags of at most 128 characters.
  func searchWorkshop(
    text: String, sort: WorkshopSort, tags: [String], excludedTags: [String],
    kind: WorkshopKind = .all
  ) async throws {
    guard text.count <= Self.maxTextLength, tags.count <= 32, tags.allSatisfy({ $0.count <= 128 }),
      excludedTags.count <= 64, excludedTags.allSatisfy({ $0.count <= 128 })
    else { throw InvalidControlValue() }
    try await run(.immediate) {
      workshop.searchText = text
      workshop.kind = kind
      workshop.sort = sort
      workshop.tags = tags
      workshop.excludedTags = excludedTags
      workshop.search()
    }
  }

  /// Shows one of the three lists from its first page, and forgets where Back would have gone.
  /// Choosing the list already on show searches it again.
  func openWorkshop(_ list: WorkshopList) async throws {
    try await run(.immediate) { workshop.open(list.source) }
  }

  /// Opens an author's wallpapers from a tile, so Back returns to the list it was opened from.
  /// `id` is the author's SteamID64.
  func openWorkshopAuthor(id: String, name: String) async throws {
    guard SteamWebSession.isSteamID(id), name.count <= 256 else { throw InvalidControlValue() }
    try await run(.immediate) { workshop.open(.creator(id: id, name: name)) }
  }

  /// Opens a collection's wallpapers. A collection is a list, never a download.
  func openWorkshopCollection(id: String, title: String) async throws {
    guard !id.isEmpty, id.count <= 20, UInt64(id) != nil, title.count <= 512 else {
      throw InvalidControlValue()
    }
    try await run(.immediate) { workshop.open(.collection(id: id, title: title)) }
  }

  /// Returns to the source the shown one was opened from; nothing when it was not opened from one.
  func workshopGoBack() async throws {
    try await run(.immediate) { workshop.back() }
  }

  /// Loads a page of the list on show. A number outside Steam's 1,000 pages is clamped into them,
  /// as the page jump always did, and one past the last page of this list is ignored.
  func showWorkshopPage(_ page: Int) async throws {
    try await run(.immediate) {
      workshop.loadPage(min(max(page, 1), WorkshopStore.maxPages))
    }
  }

  /// Asks again for the request that failed.
  func retryWorkshopSearch() async throws {
    try await run(.immediate) { workshop.retrySearch() }
  }

  /// Selects a tile. The id must be one the store knows: on the page, selected, or the item of a
  /// retained request, a running job or an update. Anything else is a stale control.
  func selectWorkshopItem(id: String) async throws {
    try await run(.immediate) {
      guard let item = workshop.workshopItem(id: id) else { throw InvalidControlValue() }
      workshop.selectedItem = item
    }
  }

  // MARK: Steam Community

  /// Signs in to Steam on its own page, in a window of its own, so Your subscriptions can be read.
  /// The app never sees the password and keeps only the session cookie, in memory. The action
  /// returns at once: a second call while the window is open brings it forward, and the sign-in's
  /// outcome (or its failure, which reaches the banner) arrives later. `signInToSteamWeb` is the
  /// seam tests answer instead of the window; `steamWebSignInTask` is what they await.
  func steamWebSignIn() async throws {
    try await run(.immediate) {
      if workshop.isSigningInToSteamWeb {
        WebSignInWindowController.bringToFront(.steam)
      } else if workshop.steamWebSession == nil {
        let obtain = signInToSteamWeb ?? { await WebSignInWindowController.obtainCookie(for: .steam) }
        steamWebSignInTask = Task { @MainActor [weak self] in
          guard let self else { return }
          do {
            try await self.workshop.signInToSteamWeb(obtainCookie: obtain)
          } catch {
            self.errors.report(error)
          }
        }
      }
    }
  }

  /// Forgets the Steam Community session; Your subscriptions empties if it was on show.
  func steamWebSignOut() async throws {
    try await run(.immediate) { workshop.signOutOfSteamWeb() }
  }

  /// Downloads every wallpaper the signed-in account subscribes to that the library lacks.
  ///
  /// Steam is read outside the command queue (that read can take a while and nothing waits for it);
  /// only the requests, which queue like single downloads, wait in it. Applications and
  /// collections are skipped, and so is any item already downloading. Nothing is subscribed or
  /// unsubscribed, and every item still needs the SteamCMD sign-in.
  func downloadSubscribedWorkshopItems() async throws {
    try await run(.direct) {
      let installed = Set(store.librarySnapshot.wallpapers.map(\.id))
      let missing = try await workshop.missingSubscriptions(installed: installed)
        .filter { $0.kind != .application }
      guard !missing.isEmpty else {
        throw WallpaperActionError(
          message: L("Every wallpaper you subscribe to is already in your library."))
      }
      try await store.commands.run {
        for item in missing where workshop.downloader.download(for: item.id)?.isPending != true {
          workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
          try checkDownloadError()
        }
      }
    }
  }

  // MARK: Updates and reinstalling

  /// Checks the installed Workshop wallpapers against Steam, unless a check is running.
  func checkWorkshopUpdates() async throws {
    try await run(.immediate) {
      workshop.updates.check(
        installed: store.librarySnapshot.wallpapers.map(\.id), library: ClientPaths.libraryURL)
    }
  }

  /// Downloads the new version of an installed wallpaper whose author changed it. It goes through
  /// the same queue and prerequisites as any item and replaces the installed copy once it has
  /// arrived whole. A wallpaper without an update has nothing to download.
  func updateWorkshopItem(id: String) async throws {
    let id = try installedWallpaperID(id)
    try await run(.queued) {
      guard let item = workshop.updates.available[id] else { throw InvalidControlValue() }
      workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    }
  }

  /// Updates every installed wallpaper that has an update, by title, skipping any already downloading.
  func updateAllWorkshopItems() async throws {
    try await run(.queued) {
      for item in workshop.updates.available.values.sorted(by: { $0.title < $1.title })
      where workshop.downloader.download(for: item.id)?.isPending != true {
        workshop.requestDownload(item: item, rememberSession: remembersSession, bridge: store)
        try checkDownloadError()
      }
    }
  }

  /// Downloads an installed Workshop wallpaper again, to repair a damaged copy or take the
  /// Workshop's current one; the new files replace the installed ones only once they have arrived
  /// whole. It asks first. The question is inside the command, as it always was, so an open sheet
  /// holds the queue.
  func reinstallWorkshopItem(id: String) async throws {
    let id = try installedWallpaperID(id)
    try await run(.queued) {
      guard
        await dialogs.confirm(
          L("Reinstall this wallpaper?"),
          detail: L(
            "WallpaperMachine downloads it again from the Steam Workshop and swaps it in when the download is complete. Your settings for it are kept, and if the download fails the installed copy stays."
          ),
          button: L("Reinstall"))
      else { return }
      try await workshop.requestReinstall(id: id, rememberSession: remembersSession, bridge: store)
      try checkDownloadError()
    }
  }
}
