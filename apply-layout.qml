import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import MuseScore 3.0

MuseScore {
    id: breaksToParts

    title: qsTr("Apply Layout to Parts")
    description: qsTr("Locks in the current layout of the score or active part and applies the same breaks and system locks to selected parts.")
    version: "2.0"
    categoryCode: "composing-arranging-tools"
    thumbnailName: "thumbnail.png"
    pluginType: "dialog"
    requiresScore: true

    width: 340
    height: 440

    property var pendingPageBreaks: []
    property var pendingLineBreaks: []
    property var pendingSectionBreaks: []
    property var pendingNoBreaks: []
    property var pendingLockedStart: []
    property var pendingLockedEnd: []
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

        if (elements.length === 0 && measLockedSystemStart.length === 0) {
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

    function stripPartNumber(title) {
        return title.toLowerCase().replace(/\s+(\d+|[ivx]+)$/i, "").trim()
    }

    function shouldPreselectPart(currTitle, targetTitle) {
        if (!currTitle || !targetTitle)
            return false

        var cBase = stripPartNumber(currTitle)
        var tBase = stripPartNumber(targetTitle)

        if (cBase.length > 0 && cBase === tBase)
            return true

        return getSimilarityScore(cBase, tBase) >= 4
    }

    function getSimilarityScore(s1, s2) {
        var maxLen = 0
        for (var i = 0; i < s1.length; i++) {
            for (var j = i + 3; j <= s1.length; j++) {
                var sub = s1.substring(i, j)
                if (s2.indexOf(sub) !== -1 && sub.length > maxLen)
                    maxLen = sub.length
            }
        }
        return maxLen
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

        // Pass 1: add breaks and nobreaks to selected parts in a single undo command
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
        if (part.systems) {
            for (var s = 0; s < part.systems.length; s++) {
                var sys = part.systems[s]
                if (sys && sys.isLocked)
                    sys.isLocked = false
            }
        }
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
            text: qsTr("No layout breaks or locked systems were found in the current score.")
        }
    }
}