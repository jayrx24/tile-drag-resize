// Panel.qml — the dropdown attached to the Tile Drag & Resize bar icon.
//
// Everything it shows comes from the service; the panel only reads state and
// calls back into it. It is fully keyboard-driven: the arrow keys / hjkl move
// a single cursor over the rows, Enter or Space activates, Esc closes.

import QtQuick
import qs.Commons
import qs.Ui

Panel {
    id: panel
    moduleName: "io.github.jayrx24.tile-drag-resize"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var service: null

    readonly property bool dragOn: panel.service ? panel.service.dragEnabled === true : false
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color accent: Color.accent
    readonly property color dim: Qt.darker(foreground, 1.55)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    readonly property string iconOn: "\u{F037D}"     // nf-md-mouse
    readonly property string iconOff: "\u{F037E}"    // nf-md-mouse_off
    readonly property string iconChevron: "\u{F0142}" // nf-md-chevron_right

    // Cursor targets, top to bottom: 0 re-apply row, 1 On tile, 2 Off tile,
    // 3 Done button.
    readonly property int cursorSlots: 4
    property int cursorIndex: -1

    function open() {
        cursorIndex = -1
        controller.show()
    }

    function close() {
        controller.hide()
    }

    function switchPanel(direction) {
        if (bar && typeof bar.switchPanelFrom === "function")
            return bar.switchPanelFrom(hostWidget || panel, direction)
        return false
    }

    function setDrag(on) {
        if (service) service.setDrag(on)
    }

    function activate(index) {
        if (index === 0) { if (service) service.reapply() }
        else if (index === 1) setDrag(true)
        else if (index === 2) setDrag(false)
        else if (index === 3) close()
    }

    function moveCursor(dx, dy) {
        var step = dx !== 0 ? dx : dy
        if (cursorIndex < 0) {
            cursorIndex = step < 0 ? cursorSlots - 1 : 0
            return
        }
        cursorIndex = Math.max(0, Math.min(cursorSlots - 1, cursorIndex + step))
    }

    KeyboardPanel {
        id: surface
        anchorItem: panel.anchorItem
        owner: panel.hostWidget || panel
        bar: panel.bar
        open: panel.opened
        focusTarget: keys
        contentWidth: surface.fittedContentWidth(Style.space(260))
        contentHeight: surface.fittedContentHeight(body.implicitHeight)

        PanelKeyCatcher {
            id: keys
            anchors.fill: parent
            onCloseRequested: panel.close()
            onTabRequested: function(direction) { panel.switchPanel(direction) }
            onMoveRequested: function(dx, dy) { panel.moveCursor(dx, dy) }
            onActivateRequested: {
                if (panel.cursorIndex < 0) panel.setDrag(!panel.dragOn)
                else panel.activate(panel.cursorIndex)
            }

            Column {
                id: body
                width: parent.width
                spacing: Style.space(10)

                // ---- state hero -------------------------------------------
                BorderSurface {
                    width: parent.width
                    height: hero.implicitHeight + Style.space(28)
                    radius: Style.cornerRadius
                    color: panel.dragOn
                        ? Qt.rgba(panel.accent.r, panel.accent.g, panel.accent.b, 0.08)
                        : "transparent"
                    borderSpec: Border.controlSpec("normal", panel.foreground, panel.accent)

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Column {
                        id: hero
                        anchors.centerIn: parent
                        spacing: Style.space(4)

                        Text {
                            textFormat: Text.PlainText
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: panel.dragOn ? panel.iconOn : panel.iconOff
                            color: panel.dragOn ? panel.accent : panel.dim
                            font.family: panel.fontFamily
                            font.pixelSize: Style.font.displayLarge * 1.6
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Tile Drag & Resize"
                            color: panel.foreground
                            font.family: panel.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                        }

                        Text {
                            textFormat: Text.PlainText
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: panel.dragOn ? "MIDDLE-DRAG ON" : "MIDDLE-DRAG OFF"
                            color: panel.dim
                            font.family: panel.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1.2
                        }
                    }
                }

                // ---- re-apply action --------------------------------------
                CursorSurface {
                    id: reapplyRow
                    width: parent.width
                    height: Style.spacing.controlHeight
                    hasCursor: panel.cursorIndex === 0
                    foreground: panel.foreground
                    accent: panel.accent

                    Text {
                        id: reapplyIcon
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(20)
                        text: "\u{F359}"   // nf-linux-hyprland
                        color: panel.foreground
                        font.family: panel.fontFamily
                        font.pixelSize: Style.font.icon
                    }

                    Text {
                        textFormat: Text.PlainText
                        anchors.left: reapplyIcon.right
                        anchors.leftMargin: Style.space(8)
                        anchors.right: reapplyChevron.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Re-apply Hyprland bind"
                        color: panel.foreground
                        font.family: panel.fontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                    }

                    Text {
                        id: reapplyChevron
                        textFormat: Text.PlainText
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        text: panel.iconChevron
                        color: panel.dim
                        font.family: panel.fontFamily
                        font.pixelSize: Style.font.icon
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: panel.cursorIndex = 0
                        onClicked: if (panel.service) panel.service.reapply()
                    }
                }

                PanelSeparator { foreground: panel.foreground }

                // ---- on / off tiles ---------------------------------------
                Row {
                    id: tiles
                    width: parent.width
                    spacing: Style.space(10)

                    Repeater {
                        model: [
                            { on: true, label: "On", icon: panel.iconOn },
                            { on: false, label: "Off", icon: panel.iconOff }
                        ]

                        delegate: CursorSurface {
                            id: tile
                            required property var modelData
                            required property int index

                            readonly property bool chosen: panel.dragOn === modelData.on

                            width: (tiles.width - tiles.spacing) / 2
                            height: tileBody.implicitHeight + Style.space(24)
                            hasCursor: panel.cursorIndex === 1 + index
                            current: chosen
                            bordered: true
                            foreground: panel.foreground
                            accent: panel.accent

                            Column {
                                id: tileBody
                                anchors.centerIn: parent
                                spacing: Style.space(4)

                                Text {
                                    textFormat: Text.PlainText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: tile.modelData.icon
                                    color: tile.chosen ? panel.accent : panel.dim
                                    font.family: panel.fontFamily
                                    font.pixelSize: Style.font.displayLarge
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: tile.modelData.label
                                    color: tile.chosen ? panel.foreground : panel.dim
                                    font.family: panel.fontFamily
                                    font.pixelSize: Style.font.body
                                    font.bold: tile.chosen
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: panel.cursorIndex = 1 + tile.index
                                onClicked: panel.setDrag(tile.modelData.on)
                            }
                        }
                    }
                }

                // ---- footer -----------------------------------------------
                Item {
                    width: parent.width
                    height: doneButton.implicitHeight

                    Text {
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.right: doneButton.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        text: panel.dragOn ? "Middle-drag moves windows" : "Middle-click goes to apps"
                        color: panel.dim
                        font.family: panel.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                    }

                    Button {
                        id: doneButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Done"
                        background: panel.accent
                        foreground: Color.background
                        accent: panel.accent
                        fontFamily: panel.fontFamily
                        hasCursor: panel.cursorIndex === 3
                        onClicked: panel.close()
                        onHovered: function(h) { if (h) panel.cursorIndex = 3 }
                    }
                }
            }
        }
    }
}
