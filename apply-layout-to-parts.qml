import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MuseScore 3.0

MuseScore {
    id: applyLayoutToParts

    title: qsTr("Apply Layout to Parts")
    description: qsTr("Locks in the current layout of the score or active part and applies the same to selected parts.")
    version: "2.1"
    categoryCode: "composing-arranging-tools"
    thumbnailName: "thumbnail.png"
    pluginType: "dialog"
    requiresScore: true

    width: 340
    height: 470

    property var pendingPageBreaks: []
    property var pendingLineBreaks: []
    property var pendingSectionBreaks: []
    property var pendingNoBreaks: []
    property var pendingLockedStart: []
    property var pendingLockedEnd: []
    property var pendingFrames: []
    property bool exportSectionBreaks: false // For now section breaks cannot be part-independent
    property int currentPartIndex: -1

    onRun: {
        if (!curScore) {
            quit()
            return
        }

        if (curScore.excerpts.length === 0) {
            excerptsError.open()
            return
        }

        curScore.startCmd()

        // Lock all currently unlocked systems in the source score
        if (curScore.systems) {
            for (var s = 0; s < curScore.systems.length; s++) {
                var sys = curScore.systems[s]
                if (sys && !sys.isLocked)
                    sys.isLocked = true
            }
        }

        var elements = []
        for (var m = curScore.firstMeasure; m; m = m.nextMeasure) {
            var me = m.elements
            for (var mei = 0; mei < me.length; ++mei) {
                var e = me[mei]
                if (e.type == Element.LAYOUT_BREAK)
                    elements.push(e)
            }
        }

        // Collect locked systems start and end measures
        var measLockedSystemStart = []
        var measLockedSystemEnd = []
        if (curScore.systems) {
            for (var s = 0; s < curScore.systems.length; s++) {
                var sys = curScore.systems[s]
                if (sys && sys.isLocked && sys.firstMeasure && sys.lastMeasure) {
                    measLockedSystemStart.push(findMeasureRangeInScore(curScore, sys.firstMeasure).start)
                    measLockedSystemEnd.push(findMeasureRangeInScore(curScore, sys.lastMeasure).end)
                }
            }
        }

        curScore.endCmd()

        // Collect frame layouts and child text positions
        pendingFrames = collectFramesData(curScore)

        if (elements.length === 0 && measLockedSystemStart.length === 0 && pendingFrames.length === 0) {
            breaksError.open()
            return
        }

        var measNoPageBreak = []
        var measNoLineBreak = []
        var measNoSectionBreak = []
        var measNoNoBreak = []

        for (var idx = 0; idx < elements.length; idx++) {
            var element = elements[idx]
            if (element.type == Element.LAYOUT_BREAK) {
                var t = element.layoutBreakType
                // Convert page breaks in main score into system breaks in parts
                if (!curScore.parent && t == LayoutBreak.PAGE)
                    t = LayoutBreak.LINE

                var targetMeasure = findMeasureRangeInScore(curScore, element.parent).end
                if (t == LayoutBreak.PAGE)
                    measNoPageBreak.push(targetMeasure)
                else if (t == LayoutBreak.LINE)
                    measNoLineBreak.push(targetMeasure)
                else if (t == LayoutBreak.SECTION)
                    measNoSectionBreak.push(targetMeasure)
                else if (t == LayoutBreak.NOBREAK)
                    measNoNoBreak.push(targetMeasure)
                else
                    console.log("Error in finding layout break type")
            }
        }

        printList(measNoPageBreak, "measNoPageBreak: ")
        printList(measNoLineBreak, "measNoLineBreak: ")
        printList(measNoSectionBreak, "measNoSectionBreak: ")
        printList(measNoNoBreak, "measNoNoBreak: ")
        printList(measLockedSystemStart, "measLockedSystemStart: ")
        printList(measLockedSystemEnd, "measLockedSystemEnd: ")

        pendingPageBreaks = measNoPageBreak
        pendingLineBreaks = measNoLineBreak
        pendingSectionBreaks = measNoSectionBreak
        pendingNoBreaks = measNoNoBreak
        pendingLockedStart = measLockedSystemStart
        pendingLockedEnd = measLockedSystemEnd

        var partsList = curScore.excerpts
        var isCurrentScoreAPart = false
        var currentPartTitle = ""
        currentPartIndex = -1

        for (var i = 0; i < partsList.length; i++) {
            if (partsList[i].partScore && partsList[i].partScore.is(curScore)) {
                isCurrentScoreAPart = true
                currentPartTitle = partsList[i].title
                currentPartIndex = i
                break
            }
        }

        partSelectionModel.clear()
        for (var i = 0; i < partsList.length; i++) {
            var pScore = partsList[i].partScore
            var isCurrent = (pScore && pScore.is(curScore)) ? true : false
            var shouldPreselect = true

            if (isCurrentScoreAPart)
                shouldPreselect = !isCurrent && shouldPreselectPart(currentPartTitle, partsList[i].title)

            partSelectionModel.append({
                partTitle: partsList[i].title,
                isCurrent: isCurrent,
                isChecked: shouldPreselect,
                partIndex: i
            })
        }

        updateAllCheckboxState()

        if (currentPartIndex >= 0) {
            Qt.callLater(function() {
                partListView.forceLayout()
                partListView.positionViewAtIndex(currentPartIndex, ListView.Center)
            })
        }
    }

    function extractFramesFromScore(score) {
        var found = []
        var seen = []

        function checkObj(obj) {
            if (!obj || seen.indexOf(obj) !== -1)
                return
            seen.push(obj)

            if (obj.type === Element.VBOX || obj.type === Element.HBOX || obj.type === Element.TBOX || obj.type === Element.FBOX) {
                found.push(obj)
            }
        }

        // 1. Check score.systems (MuseScore 4 wraps frames in System objects)
        if (score.systems) {
            for (var s = 0; s < score.systems.length; s++) {
                var sys = score.systems[s]
                if (!sys)
                    continue
                checkObj(sys)
                if (sys.firstMeasure)
                    checkObj(sys.firstMeasure)
                if (sys.measures) {
                    for (var m = 0; m < sys.measures.length; m++)
                        checkObj(sys.measures[m])
                }
                if (sys.elements) {
                    for (var e = 0; e < sys.elements.length; e++)
                        checkObj(sys.elements[e])
                }
            }
        }

        // 2. Also check score.pages -> page.elements as a fallback
        if (found.length === 0 && score.pages) {
            for (var p = 0; p < score.pages.length; p++) {
                var page = score.pages[p]
                if (page && page.elements) {
                    for (var pe = 0; pe < page.elements.length; pe++)
                        checkObj(page.elements[pe])
                }
            }
        }

        return found
    }

    function getAnchorTickForFrame(frameObj) {
        // Walk forward from the frame using nextMeasure / nextMeasureMM if available
        var next = frameObj.nextMeasure || frameObj.nextMeasureMM
        while (next) {
            if (next.type === Element.MEASURE && next.firstSegment)
                return next.firstSegment.tick
            next = next.nextMeasure || next.nextMeasureMM
        }
        return -1
    }

    function collectFramesData(score) {
        var frames = []
        var rawFrames = extractFramesFromScore(score)
        console.log("Raw frames found in source:", rawFrames.length)

        for (var idx = 0; idx < rawFrames.length; idx++) {
            var mb = rawFrames[idx]
            var nextTick = getAnchorTickForFrame(mb)

            var frameInfo = {
                type: mb.type,
                seqIndex: idx,
                anchorTick: nextTick,
                boxHeight: mb.boxHeight,
                boxWidth: mb.boxWidth,
                topMargin: mb.topMargin,
                bottomMargin: mb.bottomMargin,
                leftMargin: mb.leftMargin,
                rightMargin: mb.rightMargin,
                topGap: mb.topGap,
                bottomGap: mb.bottomGap,
                elements: []
            }

            if (mb.elements) {
                for (var i = 0; i < mb.elements.length; i++) {
                    var el = mb.elements[i]
                    if (el.type === Element.TEXT) {
                        var elData = {
                            subStyle: el.subStyle,
                            offsetX: el.offset.x,
                            offsetY: el.offset.y,
                            hasPositionProp: (typeof el.position === "number"),
                            positionVal: (typeof el.position === "number") ? el.position : -1,
                            hasAlignProp: (typeof el.align === "number" && el.align !== 0),
                            alignVal: (typeof el.align === "number") ? el.align : -1
                        }
                        frameInfo.elements.push(elData)
                    }
                }
            }
            frames.push(frameInfo)
        }
        return frames
    }

    function applyFramesToPart(part, sourceFrames) {
        if (!part || !sourceFrames || sourceFrames.length === 0)
            return

        var rawPartFrames = extractFramesFromScore(part)
        var partFrames = []
        for (var idx = 0; idx < rawPartFrames.length; idx++) {
            var mb = rawPartFrames[idx]
            partFrames.push({
                frame: mb,
                anchorTick: getAnchorTickForFrame(mb),
                matched: false
            })
        }

        for (var i = 0; i < sourceFrames.length; i++) {
            var src = sourceFrames[i]
            var target = null

            for (var j = 0; j < partFrames.length; j++) {
                if (!partFrames[j].matched &&
                    partFrames[j].frame.type === src.type &&
                    partFrames[j].anchorTick === src.anchorTick) {
                    target = partFrames[j].frame
                    partFrames[j].matched = true
                    break
                }
            }

            if (!target && i === 0 && partFrames.length > 0 && !partFrames[0].matched && partFrames[0].frame.type === src.type) {
                target = partFrames[0].frame
                partFrames[0].matched = true
            }

            if (!target)
                continue

            if (src.type === Element.VBOX || src.type === Element.TBOX || src.type === Element.FBOX)
                target.boxHeight = src.boxHeight
            if (src.type === Element.HBOX)
                target.boxWidth = src.boxWidth

            target.topMargin = src.topMargin
            target.bottomMargin = src.bottomMargin
            target.leftMargin = src.leftMargin
            target.rightMargin = src.rightMargin
            target.topGap = src.topGap
            target.bottomGap = src.bottomGap

            if (target.elements && src.elements.length > 0) {
                for (var te = 0; te < target.elements.length; te++) {
                    var tEl = target.elements[te]
                    if (tEl.type !== Element.TEXT)
                        continue

                    for (var se = 0; se < src.elements.length; se++) {
                        var sEl = src.elements[se]
                        if (tEl.subStyle === sEl.subStyle) {
                            // Copy manual X/Y offset nudges
                            tEl.offset = Qt.point(sEl.offsetX, sEl.offsetY)

                            // Only apply 4.6+ frame-position / text-align if exposed as valid numeric enums
                            if (sEl.hasPositionProp && typeof tEl.position === "number")
                                tEl.position = sEl.positionVal
                            if (sEl.hasAlignProp && typeof tEl.align === "number")
                                tEl.align = sEl.alignVal

                            break
                        }
                    }
                }
            }
        }
    }

    function extractInstrumentTokens(title) {
        if (!title)
            return []

        // Remove trailing part numbers, roman numerals, or division letters (e.g., "1", "II", "1 & 2", "A")
        var cleaned = title.replace(/[\s,.-]+(\d+(\s*[&/,-]\s*\d+)*|[IVX]+|[A-Z])$/i, "").trim()

        // Split on whitespace, slashes, hyphens, parentheses
        var rawWords = cleaned.split(/[\s/()\-]+/)
        var tokens = []

        for (var i = 0; i < rawWords.length; i++) {
            var w = rawWords[i].replace(/^[^A-Za-zÀ-ÖØ-öø-ÿ]+|[^A-Za-zÀ-ÖØ-öø-ÿ]+$/g, "")
            if (!w)
                continue

            // Ignore lowercase connector words ("in", "en", "de", "of", "the", "und", etc.)
            var firstChar = w.charAt(0)
            if (firstChar === firstChar.toLowerCase() && firstChar !== firstChar.toUpperCase())
                continue

            // Ignore ordinals like "1st", "2nd" and standalone key/transposition labels ("Bb", "Eb", "F", "C", "F#", etc.)
            if (/^\d+(st|nd|rd|th)$/i.test(w))
                continue
            if (/^[A-G]([b#♯♭])?$/.test(w))
                continue

            tokens.push(w.toLowerCase())
        }

        return tokens
    }

    function shouldPreselectPart(currTitle, targetTitle) {
        if (!currTitle || !targetTitle)
            return false

        var cTokens = extractInstrumentTokens(currTitle)
        var tTokens = extractInstrumentTokens(targetTitle)

        if (cTokens.length === 0 || tTokens.length === 0)
            return false

        // Check if every significant token in the shorter name appears in the longer name
        var shorter = cTokens.length <= tTokens.length ? cTokens : tTokens
        var longer = cTokens.length <= tTokens.length ? tTokens : cTokens

        var matches = 0
        for (var i = 0; i < shorter.length; i++) {
            if (longer.indexOf(shorter[i]) !== -1)
                matches++
        }

        return matches === shorter.length
    }

    function updateAllCheckboxState() {
        var allChecked = true
        var selectableCount = 0
        for (var i = 0; i < partSelectionModel.count; i++) {
            var item = partSelectionModel.get(i)
            if (!item.isCurrent) {
                selectableCount++
                if (!item.isChecked)
                    allChecked = false
            }
        }
        selectAllCheckbox.checked = (selectableCount > 0 && allChecked)
    }

    function applyToSelectedParts(selectedIndices) {
        if (!selectedIndices || selectedIndices.length === 0)
            return

        var partsList = curScore.excerpts

        // Pass 1: add breaks, nobreaks, and frame layouts to selected parts in a single undo command
        curScore.startCmd()
        for (var i = 0; i < selectedIndices.length; i++) {
            var partIdx = selectedIndices[i]
            var destPart = partsList[partIdx].partScore
            if (destPart && !destPart.is(curScore)) {
                console.log(partsList[partIdx].title)
                unlockSystemsInPart(destPart)
                var exportNoBreaks = (pendingLockedStart.length === 0)
                addBreaksToPart(
                    destPart,
                    pendingPageBreaks,
                    pendingLineBreaks,
                    pendingSectionBreaks,
                    pendingNoBreaks,
                    true,
                    true,
                    exportSectionBreaks,
                    exportNoBreaks
                )
                if (pendingLockedStart.length > 0)
                    lockSystemRangesInPart(destPart, pendingLockedStart, pendingLockedEnd)

                if (copyFramesCheckbox.checked)
                    applyFramesToPart(destPart, pendingFrames)
            }
        }
        curScore.endCmd()

        // Pass 2: convert the resulting systems to locked systems across selected parts in a single undo command
        if (pendingLockedStart.length > 0) {
            curScore.startCmd()
            for (var i = 0; i < selectedIndices.length; i++) {
                var partIdx = selectedIndices[i]
                var destPart = partsList[partIdx].partScore
                if (destPart && !destPart.is(curScore))
                    lockSystemsInPart(destPart)
            }
            curScore.endCmd()
        }
    }

    function printList(list, text) {
        for (var i = 0; i < list.length; i++)
            console.log(text, list[i])
    }

    function buildTickToMeasureNumMap(score) {
        var map = {}
        var ticks = {}
        var idx = 1
        for (var m = score.firstMeasure; m; m = m.nextMeasure) {
            if (m.firstSegment) {
                map[m.firstSegment.tick] = idx
                ticks[idx] = m.firstSegment.tick
            }
            idx++
        }
        return { map: map, ticks: ticks, total: idx - 1 }
    }

    function buildMMRestEndMap(part, info) {
        var mmEndMap = {}
        var mm = part.firstMeasureMM
        while (mm) {
            if (mm.firstSegment) {
                var startN = info.map[mm.firstSegment.tick] || 0
                if (startN > 0) {
                    var endN = startN
                    if (mm.nextMeasureMM && mm.nextMeasureMM.firstSegment) {
                        var nextStartN = info.map[mm.nextMeasureMM.firstSegment.tick] || 0
                        if (nextStartN > startN)
                            endN = nextStartN - 1
                    } else if (!mm.nextMeasureMM) {
                        endN = info.total
                    }

                    if (endN > startN) {
                        for (var k = startN; k <= endN; k++)
                            mmEndMap[k] = endN
                    }
                }
            }
            mm = mm.nextMeasureMM
        }
        return mmEndMap
    }

    function findMeasureRangeInScore(score, mea) {
        if (!score || !mea || !mea.firstSegment)
            return { start: 0, end: 0 }

        var info = buildTickToMeasureNumMap(score)
        var start = info.map[mea.firstSegment.tick] || 0
        if (start === 0)
            return { start: 0, end: 0 }

        return { start: start, end: start }
    }

    function getLayoutBreak(m) {
        var me = m.elements
        for (var mei = 0; mei < me.length; ++mei) {
            var e = me[mei]
            if (e.type == Element.LAYOUT_BREAK)
                return e
        }
        return 0
    }

    function unlockSystemsInPart(part) {
        if (!part)
            return

        if (part.systems) {
            for (var s = 0; s < part.systems.length; s++) {
                var sys = part.systems[s]
                if (sys && sys.isLocked)
                    sys.isLocked = false
            }
        }

        // Remove all existing layout breaks (page, line, nobreak, and optionally section)
        var toRemove = []
        for (var m = part.firstMeasure; m; m = m.nextMeasure) {
            var me = m.elements
            for (var mei = 0; mei < me.length; ++mei) {
                var e = me[mei]
                if (e.type == Element.LAYOUT_BREAK) {
                    if (e.layoutBreakType != LayoutBreak.SECTION || exportSectionBreaks)
                        toRemove.push(e)
                }
            }
        }
        for (var r = 0; r < toRemove.length; r++)
            removeElement(toRemove[r])
    }

    function lockSystemsInPart(part) {
        if (part && part.systems) {
            for (var s = 0; s < part.systems.length; s++) {
                var sys = part.systems[s]
                if (sys && !sys.isLocked)
                    sys.isLocked = true
            }
        }

        // Remove any temporary NOBREAK or leftover LINE break elements
        if (part) {
            var toRemove = []
            for (var m = part.firstMeasure; m; m = m.nextMeasure) {
                var me = m.elements
                for (var mei = 0; mei < me.length; ++mei) {
                    var e = me[mei]
                    if (e.type == Element.LAYOUT_BREAK && (e.layoutBreakType == LayoutBreak.NOBREAK || e.layoutBreakType == LayoutBreak.LINE))
                        toRemove.push(e)
                }
            }
            for (var r = 0; r < toRemove.length; r++)
                removeElement(toRemove[r])
        }
    }

    function addBreaksToPart(part, pageArray, lineArray, sectionArray, noBreakArray, exportPageBreaks, exportLineBreaks, exportSectionBreaks, exportNoBreaks) {
        var info = buildTickToMeasureNumMap(part)
        var mmEndMap = buildMMRestEndMap(part, info)

        function remapToMMRestEnd(arr) {
            var map = {}
            if (arr) {
                for (var i = 0; i < arr.length; i++) {
                    var target = mmEndMap[arr[i]] || arr[i]
                    map[target] = true
                }
            }
            return map
        }

        var pageMap = remapToMMRestEnd(pageArray)
        var lineMap = remapToMMRestEnd(lineArray)
        var sectionMap = remapToMMRestEnd(sectionArray)
        var noBreakMap = remapToMMRestEnd(noBreakArray)
        var cursor = part.newCursor()

        for (var m = part.firstMeasure; m; m = m.nextMeasure) {
            if (!m.firstSegment)
                continue

            var n = info.map[m.firstSegment.tick] || 0
            if (n === 0)
                continue

            if (getLayoutBreak(m))
                continue

            var addedType = -1
            if (exportPageBreaks && pageMap[n])
                addedType = LayoutBreak.PAGE
            else if (exportLineBreaks && lineMap[n])
                addedType = LayoutBreak.LINE
            else if (exportSectionBreaks && sectionMap[n])
                addedType = LayoutBreak.SECTION
            else if (exportNoBreaks && noBreakMap[n])
                addedType = LayoutBreak.NOBREAK

            if (addedType !== -1) {
                var brk = newElement(Element.LAYOUT_BREAK)
                brk.layoutBreakType = addedType
                cursor.rewindToTick(m.firstSegment.tick)
                cursor.add(brk)
            }
        }
    }

    function lockSystemRangesInPart(part, startArray, endArray) {
        var info = buildTickToMeasureNumMap(part)
        var mmEndMap = buildMMRestEndMap(part, info)

        function remapToMMRestEnd(arr) {
            var map = {}
            if (arr) {
                for (var i = 0; i < arr.length; i++) {
                    var target = mmEndMap[arr[i]] || arr[i]
                    map[target] = true
                }
            }
            return map
        }

        var endMap = remapToMMRestEnd(endArray)
        var cursor = part.newCursor()

        for (var m = part.firstMeasure; m; m = m.nextMeasure) {
            if (!m.firstSegment)
                continue

            var n = info.map[m.firstSegment.tick] || 0
            if (n === 0)
                continue

            var hasEndInRange = endMap[n] && (n < info.total)
            var existingBreak = getLayoutBreak(m)

            if (hasEndInRange) {
                if (!existingBreak) {
                    var lineBrk = newElement(Element.LAYOUT_BREAK)
                    lineBrk.layoutBreakType = LayoutBreak.LINE
                    cursor.rewindToTick(m.firstSegment.tick)
                    cursor.add(lineBrk)
                }
            } else if (n < info.total && !existingBreak) {
                var noBrk = newElement(Element.LAYOUT_BREAK)
                noBrk.layoutBreakType = LayoutBreak.NOBREAK
                cursor.rewindToTick(m.firstSegment.tick)
                cursor.add(noBrk)
            }
        }
    }

    ListModel {
        id: partSelectionModel
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        Label {
            text: qsTr("Select parts to copy layout breaks to:")
            font.bold: true
            Layout.fillWidth: true
        }

        CheckBox {
            id: copyFramesCheckbox

            text: qsTr("Copy frame heights, margins & text positions")
            checked: true
        }

        MenuSeparator {
            Layout.fillWidth: true
        }

        CheckBox {
            id: selectAllCheckbox

            text: qsTr("All Parts")
            font.bold: true
            onToggled: {
                for (var i = 0; i < partSelectionModel.count; i++) {
                    if (!partSelectionModel.get(i).isCurrent)
                        partSelectionModel.setProperty(i, "isChecked", selectAllCheckbox.checked)
                }
            }
        }

        MenuSeparator {
            Layout.fillWidth: true
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                id: partListView

                model: partSelectionModel
                spacing: 4

                delegate: Item {
                    width: partListView.width
                    height: 28

                    CheckBox {
                        visible: !model.isCurrent
                        text: model.partTitle
                        checked: model.isChecked
                        anchors.verticalCenter: parent.verticalCenter
                        onToggled: {
                            partSelectionModel.setProperty(index, "isChecked", checked)
                            updateAllCheckboxState()
                        }
                    }

                    Label {
                        visible: model.isCurrent
                        text: model.partTitle + qsTr(" (current)")
                        opacity: 0.65
                        anchors.left: parent.left
                        anchors.leftMargin: 32
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Item {
                Layout.fillWidth: true
            }

            Button {
                text: qsTr("Cancel")
                onClicked: quit()
            }

            Button {
                text: qsTr("OK")
                onClicked: {
                    var selected = []
                    for (var i = 0; i < partSelectionModel.count; i++) {
                        var item = partSelectionModel.get(i)
                        if (!item.isCurrent && item.isChecked)
                            selected.push(item.partIndex)
                    }
                    applyToSelectedParts(selected)
                    quit()
                }
            }
        }
    }

    Dialog {
        id: excerptsError

        title: qsTr("No Parts Found")
        modal: true
        standardButtons: Dialog.Ok
        onAccepted: quit()
        onRejected: quit()

        Label {
            text: qsTr("This score has no parts to apply the layout to.")
        }
    }

    Dialog {
        id: breaksError

        title: qsTr("No Layout Breaks Found")
        modal: true
        standardButtons: Dialog.Ok
        onAccepted: quit()
        onRejected: quit()

        Label {
            text: qsTr("No layout breaks, locked systems, or frames were found in the current score.")
        }
    }
}
