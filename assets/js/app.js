import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

const Hooks = {}

// Syncs the calendar booking grid's scroll position to the date header
// (horizontal) and the room-list sidebar (vertical).
Hooks.CalendarGrid = {
  mounted() {
    const grid = this.el
    grid.addEventListener("scroll", () => {
      const header  = document.getElementById("date-header")
      const sidebar = document.getElementById("sidebar-scroll")
      if (header)  header.scrollLeft  = grid.scrollLeft
      if (sidebar && sidebar.scrollTop !== grid.scrollTop) {
        sidebar.scrollTop = grid.scrollTop
      }
    }, { passive: true })
  }
}

// Drag-to-select on empty calendar cells. mousedown on a row-cell starts
// tracking; mousemove extends the selection within the same row; mouseup
// dispatches "quick_create" with the room_id, start col, and nights span,
// plus the screen coords so the server-rendered menu can position itself.
//
// Also handles drag on existing booking pills: the first/last 8px of the
// pill resize the stay (move check-in / check-out); the middle moves the
// whole stay — shifting dates and/or changing rooms (drop into a different
// row). On mouseup pushes "update_stay_position" with the deltas + new
// room id. Pure clicks (no movement) fall through to phx-click so the
// quick menu still works.
Hooks.CalendarSelect = {
  mounted() {
    this.drag = null
    this.pillDrag = null
    this.overlay = null
    this.edgeZone = 8
    this.threshold = 4

    this.onDown = (e) => this.startDrag(e)
    this.onMove = (e) => this.extendDrag(e)
    this.onUp   = (e) => this.endDrag(e)

    this.el.addEventListener("mousedown", this.onDown)
    document.addEventListener("mousemove", this.onMove)
    document.addEventListener("mouseup", this.onUp)
  },
  destroyed() {
    document.removeEventListener("mousemove", this.onMove)
    document.removeEventListener("mouseup", this.onUp)
    this.clearOverlay()
  },
  startDrag(e) {
    if (e.button !== 0) return

    // Branch A: mousedown on existing booking pill → pill drag flow.
    const pill = e.target.closest(".booking")
    if (pill) return this.startPillDrag(e, pill)

    // Branch B: mousedown on empty row cell → drag-to-create flow.
    const cell = e.target.closest(".row-cell")
    if (!cell) return
    const row = cell.closest(".row")
    if (!row) return
    this.clearOverlay()
    this.drag = { row, startCol: +cell.dataset.col, endCol: +cell.dataset.col }
    this.el.classList.add("dragging")
    this.drawOverlay()
    e.preventDefault()
  },
  startPillDrag(e, pill) {
    const rect = pill.getBoundingClientRect()
    const x = e.clientX - rect.left

    let mode
    if (x < this.edgeZone) mode = "resize-start"
    else if (x > rect.width - this.edgeZone) mode = "resize-end"
    else mode = "move"

    const sample = this.el.querySelector(".row-cell")
    if (!sample) return
    const cellW = sample.getBoundingClientRect().width

    this.pillDrag = {
      pill, mode, cellW,
      startX: e.clientX, startY: e.clientY,
      origLeft: parseFloat(pill.style.left || "0"),
      origWidth: parseFloat(pill.style.width || rect.width),
      origStyleWidth: pill.style.width || "",
      origRow: pill.closest(".row"),
      deltaStart: 0,
      deltaEnd: 0,
      newRow: null,
      moved: false
    }
    pill.classList.add("dragging-pill")
    // Also disable transition inline so a stale stylesheet can't animate
    // the cursor-following transform.
    pill.style.transition = "none"
    e.preventDefault()
  },
  extendDrag(e) {
    if (this.pillDrag) return this.extendPillDrag(e)

    if (!this.drag) return
    // Find the cell under the cursor — must be in the same row to extend.
    const el = document.elementFromPoint(e.clientX, e.clientY)
    const cell = el && el.closest && el.closest(".row-cell")
    if (!cell) return
    if (cell.closest(".row") !== this.drag.row) return
    const col = +cell.dataset.col
    if (col !== this.drag.endCol) {
      this.drag.endCol = col
      this.drawOverlay()
    }
  },
  extendPillDrag(e) {
    const d = this.pillDrag
    const dx = e.clientX - d.startX
    const dy = e.clientY - d.startY
    // Threshold checks both axes — purely vertical drags (drop into a
    // different room without sliding horizontally) need to start tracking
    // too, otherwise the pill never reacts until the user wiggles sideways.
    if (!d.moved && Math.abs(dx) < this.threshold && Math.abs(dy) < this.threshold) return
    d.moved = true

    const cellW = d.cellW
    // Pill width = nights * cellW - 4px (the small gap between pills),
    // so origWidth / cellW under-counts by one when floored. Round
    // instead. (Also exposed via the pill's data-w attribute.)
    const maxNights = parseInt(d.pill.dataset.w, 10) || Math.round(d.origWidth / cellW)

    if (d.mode === "move") {
      // Track row under cursor for cross-room drag.
      const under = document.elementFromPoint(e.clientX, e.clientY)
      const row   = under && under.closest && under.closest(".row")
      d.newRow = row && row.dataset.roomId ? row : null
      // Snapped delta is what we'll send on mouseup; rounded once.
      d.deltaStart = Math.round(dx / cellW)
      d.deltaEnd   = d.deltaStart

      // Use *raw* pixel dx during drag for a smooth follow-the-cursor
      // feel — snapping only happens on release.
      const yOffset =
        d.newRow && d.newRow !== d.origRow
          ? d.newRow.getBoundingClientRect().top - d.origRow.getBoundingClientRect().top
          : 0
      d.pill.style.transform = `translate3d(${dx}px, ${yOffset}px, 0)`
    } else if (d.mode === "resize-start") {
      // Clamp so the stay keeps at least 1 night.
      const maxDeltaPx = (maxNights - 1) * cellW
      const safeDx     = Math.min(dx, maxDeltaPx)
      d.deltaStart = Math.round(safeDx / cellW)
      d.pill.style.transform = `translate3d(${safeDx}px, 0, 0)`
      d.pill.style.width = `${d.origWidth - safeDx}px`
    } else if (d.mode === "resize-end") {
      const minDeltaPx = -(maxNights - 1) * cellW
      const safeDx     = Math.max(dx, minDeltaPx)
      d.deltaEnd = Math.round(safeDx / cellW)
      d.pill.style.width = `${d.origWidth + safeDx}px`
    }
  },
  endDrag(e) {
    if (this.pillDrag) return this.endPillDrag(e)

    if (!this.drag) return
    const { row, startCol, endCol } = this.drag
    const [s, t] = startCol <= endCol ? [startCol, endCol] : [endCol, startCol]
    const nights = t - s + 1
    // Drop the live-drag overlay; the server re-renders an equivalent overlay
    // inside the row template that survives subsequent DOM patches.
    this.clearOverlay()
    this.el.classList.remove("dragging")
    this.drag = null
    this.pushEvent("quick_create", {
      room_id: row.dataset.roomId,
      start_col: s,
      nights: nights,
      x: e.clientX,
      y: e.clientY
    })
  },
  endPillDrag(_e) {
    const d = this.pillDrag
    d.pill.classList.remove("dragging-pill")
    // Always clear the live-drag inline overrides. The LV will re-render
    // the pill at the proposed position (with the .pending-confirm class
    // added server-side) once it receives propose_stay_change, so any
    // brief frame between this reset and the server render is invisible.
    d.pill.style.transform = ""
    d.pill.style.width = d.origStyleWidth
    d.pill.style.transition = ""
    this.pillDrag = null

    if (!d.moved) return  // pure click — let phx-click fire normally

    // Swallow the click that follows a drag so the quick menu doesn't open.
    const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault() }
    document.addEventListener("click", swallow, { capture: true, once: true })

    const stayId = (d.pill.id || "").replace("stay-", "")
    if (!stayId) return

    const params = {
      stay_id:     stayId,
      delta_start: d.deltaStart,
      delta_end:   d.deltaEnd,
      // Pass the cursor coords so the LV can position the confirm popover
      // anchored where the user released the drag.
      x:           Math.round(_e.clientX),
      y:           Math.round(_e.clientY)
    }

    if (d.mode === "move" && d.newRow && d.newRow !== d.origRow) {
      params.room_id = d.newRow.dataset.roomId
    }

    const noChange = params.delta_start === 0 && params.delta_end === 0 && !params.room_id
    if (noChange) return

    // Don't apply immediately — surface a confirm popup with before/after.
    this.pushEvent("propose_stay_change", params)
  },
  drawOverlay() {
    const { row, startCol, endCol } = this.drag
    const [s, t] = startCol <= endCol ? [startCol, endCol] : [endCol, startCol]
    const sample = row.querySelector(".row-cell")
    if (!sample) return
    const cellW = sample.getBoundingClientRect().width
    if (!this.overlay) {
      this.overlay = document.createElement("div")
      this.overlay.className = "select-overlay"
      row.appendChild(this.overlay)
    } else if (this.overlay.parentNode !== row) {
      row.appendChild(this.overlay)
    }
    // Match the booking pill geometry: half-cell offset (check-in noon →
    // checkout noon) so the selection visually aligns with real bookings.
    this.overlay.style.left  = `${(s + 0.5) * cellW}px`
    this.overlay.style.width = `${(t - s + 1) * cellW - 4}px`
  },
  clearOverlay() {
    if (this.overlay) this.overlay.remove()
    this.overlay = null
  }
}

// Positions the quick-actions popover next to its source pill. Flips vertically
// if there isn't enough room below.
Hooks.QuickMenu = {
  mounted() { this.place() },
  updated() { this.place() },
  place() {
    const stayId = this.el.dataset.stayId
    const pill   = document.getElementById(`stay-${stayId}`)
    if (!pill) return
    const rect = pill.getBoundingClientRect()
    const menuH = this.el.offsetHeight || 220
    const menuW = this.el.offsetWidth  || 240
    const gap = 4

    const wantTop = rect.bottom + gap
    const flip    = wantTop + menuH > window.innerHeight - 16
    const top     = flip ? rect.top - menuH - gap : wantTop
    const left    = Math.min(
      Math.max(8, rect.left),
      window.innerWidth - menuW - 8
    )
    this.el.style.top  = `${Math.max(8, top)}px`
    this.el.style.left = `${left}px`
  }
}

// Positions a popover at fixed (x,y) read from data attributes, with simple
// edge-flip so it stays on screen. Used by the create-actions menu after a
// drag selection.
Hooks.AtPoint = {
  mounted() { this.place() },
  updated() { this.place() },
  place() {
    const x = +this.el.dataset.x || 0
    const y = +this.el.dataset.y || 0
    const w = this.el.offsetWidth  || 220
    const h = this.el.offsetHeight || 160
    const left = Math.min(Math.max(8, x), window.innerWidth - w - 8)
    const top  = (y + h + 8 > window.innerHeight) ? Math.max(8, y - h - 8) : y + 8
    this.el.style.left = `${left}px`
    this.el.style.top  = `${top}px`
  }
}

// Drag-to-select bulk edit on inventory cells. mousedown on an editable cell
// starts the drag; mousemove within the same room-type + metric extends the
// selection; mouseup pushes the chosen dates to the server. A pure click
// (no drag) falls through to the cell's existing phx-click for single-cell
// editing.
Hooks.InventorySelect = {
  mounted() {
    this.drag = null
    this.onDown = (e) => this.startDrag(e)
    this.onMove = (e) => this.extendDrag(e)
    this.onUp   = (e) => this.endDrag(e)
    this.el.addEventListener("mousedown", this.onDown)
    document.addEventListener("mousemove", this.onMove)
    document.addEventListener("mouseup", this.onUp)
  },
  destroyed() {
    document.removeEventListener("mousemove", this.onMove)
    document.removeEventListener("mouseup", this.onUp)
  },
  startDrag(e) {
    if (e.button !== 0) return
    const cell = e.target.closest(".cell")
    if (!cell) return
    if (cell.classList.contains("avail")) return    // read-only
    const rt    = cell.getAttribute("data-rt")
    const field = cell.getAttribute("data-field")
    const col   = +cell.getAttribute("data-col")
    if (!rt || !field || Number.isNaN(col)) return
    this.drag = { rt, field, startCol: col, endCol: col, moved: false }
  },
  extendDrag(e) {
    if (!this.drag) return
    const el = document.elementFromPoint(e.clientX, e.clientY)
    const cell = el && el.closest && el.closest(".cell")
    if (!cell) return
    if (cell.getAttribute("data-rt") !== this.drag.rt) return
    if (cell.getAttribute("data-field") !== this.drag.field) return
    const col = +cell.getAttribute("data-col")
    if (col !== this.drag.endCol) {
      this.drag.endCol = col
      this.drag.moved = true
      this.paintPreview()
    }
  },
  endDrag(e) {
    if (!this.drag) return
    const { rt, field, startCol, endCol, moved } = this.drag
    this.clearPreview()
    this.drag = null
    if (!moved) return                              // pure click → fall through

    // Swallow the click that follows a real drag so phx-click doesn't fire.
    const swallow = (ev) => { ev.stopPropagation(); ev.preventDefault() }
    document.addEventListener("click", swallow, { capture: true, once: true })

    const [s, t] = startCol <= endCol ? [startCol, endCol] : [endCol, startCol]
    const dates = []
    for (let c = s; c <= t; c++) {
      const cell = document.querySelector(
        `.cell[data-rt="${rt}"][data-field="${field}"][data-col="${c}"]`)
      if (cell) dates.push(cell.getAttribute("data-date"))
    }
    if (dates.length > 0) this.pushEvent("bulk_select", { rt, field, dates })
  },
  paintPreview() {
    this.clearPreview()
    const { rt, field, startCol, endCol } = this.drag
    const [s, t] = startCol <= endCol ? [startCol, endCol] : [endCol, startCol]
    for (let c = s; c <= t; c++) {
      const cell = document.querySelector(
        `.cell[data-rt="${rt}"][data-field="${field}"][data-col="${c}"]`)
      if (cell) cell.setAttribute("data-drag-sel", "1")
    }
  },
  clearPreview() {
    document.querySelectorAll('[data-drag-sel="1"]')
      .forEach(el => el.removeAttribute("data-drag-sel"))
  }
}

// Inline cell editor used on the inventory page. Focuses the input, selects
// its contents, commits on blur / Enter, cancels on Escape.
Hooks.InlineEdit = {
  mounted() {
    const input = this.el.querySelector("input")
    if (!input) return
    input.value = this.el.dataset.value || ""
    input.focus()
    input.select()

    // Live preview: push every keystroke so any cells in an active bulk
    // selection update together as the user types. Server no-ops on invalid
    // values (empty, NaN, out of range).
    this.onInput = () => this.pushEvent("bulk_preview", { value: input.value })
    this.onBlur  = () => this.pushEvent("commit_edit", { value: input.value })
    this.onKey   = (e) => {
      if (e.key === "Enter")  { e.preventDefault(); input.blur() }
      if (e.key === "Escape") { e.preventDefault(); this.pushEvent("cancel_edit", {}) }
    }
    input.addEventListener("input", this.onInput)
    input.addEventListener("blur", this.onBlur)
    input.addEventListener("keydown", this.onKey)
  }
}

// Auto-dismisses a flash toast (the bottom-corner "✓ Saved" pill) after
// 3.5s. Resets the timer if the message changes so a fresh action gets
// the full window before fading out.
Hooks.AutoDismiss = {
  mounted() { this.startTimer() },
  updated() { this.startTimer() },
  destroyed() { if (this.timer) clearTimeout(this.timer) },
  startTimer() {
    if (this.timer) clearTimeout(this.timer)
    const ms = parseInt(this.el.dataset.ms, 10) || 3500
    this.timer = setTimeout(() => {
      this.pushEvent("dismiss_flash", {})
    }, ms)
  }
}

// Scroll-spy + smooth-jump for the Settings property page. Mounted on the
// scrollable body (`#set-scroll`). Watches `.set-sect[id]` children and
// updates `[data-active]` on the matching `.set-subnav a` and `.set-rail-sub`
// elements. Clicking any of those targets smoothly scrolls to the section.
// Offset is read from `data-offset` (default 80, matches the sticky chrome).
Hooks.SettingsScrollSpy = {
  mounted() {
    this.offset = parseInt(this.el.dataset.offset || "80", 10)
    this.scroller = this.el
    this.refresh()

    this.onScroll = () => this.update()
    this.scroller.addEventListener("scroll", this.onScroll, { passive: true })

    this.onClick = (e) => {
      const a = e.target.closest("[data-anchor]")
      if (!a) return
      const id = a.dataset.anchor
      const el = document.getElementById(id)
      if (!el || !this.scroller.contains(el)) return
      e.preventDefault()
      const top = el.offsetTop - 16
      this.scroller.scrollTo({ top, behavior: "smooth" })
      this.setActive(id)
    }
    document.addEventListener("click", this.onClick)

    // Initial spy
    requestAnimationFrame(() => this.update())
  },
  updated() { this.refresh() },
  destroyed() {
    this.scroller.removeEventListener("scroll", this.onScroll)
    document.removeEventListener("click", this.onClick)
  },
  refresh() {
    this.sections = Array.from(this.el.querySelectorAll(".set-sect[id]"))
  },
  update() {
    if (!this.sections || !this.sections.length) return
    const top = this.scroller.scrollTop
    let current = this.sections[0].id
    for (const s of this.sections) {
      if (s.offsetTop - this.offset <= top) current = s.id
    }
    this.setActive(current)
  },
  setActive(id) {
    document.querySelectorAll(".set-subnav a[data-anchor], .set-rail-sub[data-anchor]")
      .forEach(el => {
        if (el.dataset.anchor === id) el.setAttribute("data-active", "1")
        else el.removeAttribute("data-active")
      })
  }
}

// Syncs the sidebar's vertical scroll back to the grid so both stay in step
// when the user scrolls the room list.
Hooks.SidebarScroll = {
  mounted() {
    this.el.addEventListener("scroll", () => {
      const grid = document.getElementById("grid-scroll")
      if (grid && grid.scrollTop !== this.el.scrollTop) {
        grid.scrollTop = this.el.scrollTop
      }
    }, { passive: true })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks
})

liveSocket.connect()
window.liveSocket = liveSocket
