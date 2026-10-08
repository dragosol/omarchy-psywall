import QtQuick
import qs.Commons
import qs.Ui

// Hue setup, shown in the psywall card in place of the show: find the bridge,
// press its link button, choose the lights. All state and the helper
// processes live on the widget (`view`), so pairing carries on if the card
// closes while someone walks to the bridge.
Column {
  id: setup
  property var view: null

  readonly property color fg: Color.popups.text
  readonly property color dim: Util.alpha(fg, 0.6)
  readonly property color faint: Util.alpha(fg, 0.38)
  readonly property string family: view ? view.fontFamily : Style.font.family
  readonly property string step: view ? view.setupStep : "find"

  spacing: Style.space(14)

  // ---- header --------------------------------------------------------------
  Item {
    width: parent.width
    implicitHeight: Math.max(titleCol.implicitHeight, closeBtn.height)

    Column {
      id: titleCol
      anchors.left: parent.left
      anchors.right: closeBtn.left
      spacing: Style.space(4)
      Text {
        textFormat: Text.PlainText
        text: view && view.paired && setup.step !== "link" ? "Hue lights" : "Connect Philips Hue"
        color: setup.fg
        font.family: setup.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
      Row {
        spacing: Style.space(6)
        Repeater {
          model: [{ k: "find", t: "1  Bridge" }, { k: "link", t: "2  Link button" }, { k: "lights", t: "3  Lights" }]
          delegate: Row {
            required property var modelData
            required property int index
            spacing: Style.space(6)
            readonly property int at: setup.step === "find" ? 0 : setup.step === "link" ? 1 : 2
            Text {
              textFormat: Text.PlainText
              text: modelData.t
              color: index === parent.at ? setup.fg : (index < parent.at ? setup.dim : setup.faint)
              font.family: setup.family
              font.pixelSize: Style.font.caption
              font.bold: index === parent.at
              font.letterSpacing: 0.8
            }
            Text {
              textFormat: Text.PlainText
              visible: index < 2
              text: "—"
              color: setup.faint
              font.family: setup.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    Rectangle {
      id: closeBtn
      anchors.right: parent.right
      anchors.top: parent.top
      width: Style.space(24)
      height: Style.space(24)
      radius: Style.cornerRadius
      color: closeArea.containsMouse ? Style.hoverFill : "transparent"
      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: "󰅖"
        color: setup.fg
        opacity: 0.7
        font.family: setup.family
        font.pixelSize: Style.font.subtitle
      }
      MouseArea {
        id: closeArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: view.closeSetup()
      }
    }
  }

  PanelSeparator { width: parent.width; foreground: setup.fg; strength: 0.08 }

  // ---- error ----------------------------------------------------------------
  Text {
    visible: !!view && view.setupError !== ""
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: view ? view.setupError : ""
    color: Color.accent
    font.family: setup.family
    font.pixelSize: Style.font.bodySmall
  }

  // ======================================================================
  // 1. find the bridge
  // ======================================================================
  Column {
    visible: setup.step === "find"
    width: parent.width
    spacing: Style.space(10)

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: !view ? "" : view.setupBusy && !view.bridges.length ? "Looking for Hue bridges on your network…"
        : view.bridges.length ? (view.bridges.length === 1 ? "Found your bridge." : "Found " + view.bridges.length + " bridges. Pick yours.")
        : "No bridge answered. Make sure it's powered and on the same network as this computer, or type its address below (Hue app → Settings → Bridges → ⓘ → IP address)."
      color: setup.dim
      font.family: setup.family
      font.pixelSize: Style.font.bodySmall
    }

    Repeater {
      model: view ? view.bridges : []
      delegate: Rectangle {
        required property var modelData
        width: setup.width
        implicitHeight: bRow.implicitHeight + Style.space(18)
        radius: Style.cornerRadius
        color: Util.alpha(setup.fg, 0.04)
        border.width: 1
        border.color: Util.alpha(setup.fg, 0.1)
        Item {
          id: bRow
          anchors.fill: parent
          anchors.margins: Style.space(9)
          implicitHeight: Math.max(bIcon.height, bText.implicitHeight, bBtn.implicitHeight)
          BridgeIcon { id: bIcon; size: Style.space(30); anchors.verticalCenter: parent.verticalCenter; fg: setup.fg }
          Column {
            id: bText
            anchors.left: bIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: bBtn.left
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: modelData.name
              color: setup.fg
              font.family: setup.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: [modelData.model, modelData.addr].filter(function(x) { return !!x }).join(" · ")
              color: setup.dim
              font.family: setup.family
              font.pixelSize: Style.font.caption
            }
          }
          Button {
            id: bBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Pair"
            fontFamily: setup.family
            foreground: setup.fg
            bordered: true
            onClicked: view.pairWith(modelData.addr, modelData.name)
          }
        }
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(8)
      TextField {
        id: addrField
        width: parent.width - pairBtn.width - searchBtn.width - (view && view.paired ? backBtnW : 0) - (view && view.paired ? 3 : 2) * parent.spacing
        readonly property real backBtnW: Style.space(64)
        placeholderText: "Bridge IP address, e.g. 192.168.1.20"
        font.family: setup.family
        font.pixelSize: Style.font.bodySmall
        foreground: setup.fg
        inputMethodHints: Qt.ImhPreferNumbers | Qt.ImhNoPredictiveText
        validator: RegularExpressionValidator { regularExpression: /[0-9a-fA-F.:\[\]]{0,45}/ }
        onAccepted: if (text) view.pairWith(text, "")
      }
      Button {
        id: pairBtn
        text: "Pair"
        enabled: addrField.text.length > 6
        opacity: enabled ? 1 : 0.45
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        onClicked: view.pairWith(addrField.text, "")
      }
      Button {
        visible: !!view && view.paired
        text: "Back"
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        tooltipText: "Keep the bridge you have"
        onClicked: { view.setupStep = "lights"; view.loadInventory() }
      }
      Button {
        id: searchBtn
        text: view && view.setupBusy ? "Searching…" : "Search again"
        iconText: "󰑐"
        iconSpinning: !!view && view.setupBusy
        enabled: !!view && !view.setupBusy
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        onClicked: view.discover()
      }
    }
  }

  // ======================================================================
  // 2. the link button
  // ======================================================================
  Column {
    visible: setup.step === "link"
    width: parent.width
    spacing: Style.space(14)

    Item {
      width: parent.width
      height: Style.space(150)

      // The bridge from above: a rounded square with the round link button.
      Rectangle {
        id: bridgeTop
        anchors.centerIn: parent
        width: Style.space(120)
        height: width
        radius: width * 0.22
        color: Util.alpha(setup.fg, 0.07)
        border.width: Math.max(1, Style.space(2))
        border.color: Util.alpha(setup.fg, 0.35)
        Rectangle {
          id: linkRing
          anchors.centerIn: parent
          width: parent.width * 0.42
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Math.max(2, Style.space(3))
          border.color: Color.accent
          SequentialAnimation on scale {
            running: setup.step === "link" && view && view.setupBusy
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 1.45; duration: 900; easing.type: Easing.OutCubic }
            NumberAnimation { from: 1.45; to: 1.0; duration: 0 }
            PauseAnimation { duration: 300 }
          }
          SequentialAnimation on opacity {
            running: setup.step === "link" && view && view.setupBusy
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.0; duration: 900; easing.type: Easing.OutCubic }
            NumberAnimation { from: 0.0; to: 1.0; duration: 0 }
            PauseAnimation { duration: 300 }
          }
        }
        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.36
          height: width
          radius: width / 2
          color: Util.alpha(setup.fg, 0.12)
          border.width: Math.max(1, Style.space(2))
          border.color: Util.alpha(setup.fg, 0.55)
        }
        Rectangle {   // the little status lights along the front edge
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: parent.height * 0.1
          width: parent.width * 0.3
          height: Math.max(2, Style.space(3))
          radius: height
          color: Util.alpha(Color.accent, 0.7)
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: view && !view.setupBusy && view.pairLeft <= 0 ? "The button wasn't pressed in time." : "Press the round button on top of your Hue Bridge"
      color: setup.fg
      font.family: setup.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: !view ? "" : !view.setupBusy ? "Press it, then try again: the bridge only listens for 30 seconds after the press."
        : (!view.pairReachable ? "Can't reach " + view.pairAddr + " right now. Still trying…"
          : "Psywall is asking " + view.pairName + " (" + view.pairAddr + ") for access. Waiting " + Math.floor(view.pairLeft / 60) + ":" + ("0" + view.pairLeft % 60).slice(-2))
      color: setup.dim
      font.family: setup.family
      font.pixelSize: Style.font.bodySmall
    }
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.space(10)
      Button {
        visible: !!view && !view.setupBusy
        text: "Try again"
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        onClicked: view.pairWith(view.pairAddr, view.pairName)
      }
      Button {
        text: view && view.setupBusy ? "Cancel" : "Back"
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        onClicked: { pairProcStop(); view.setupStep = "find"; view.setupBusy = false }
        function pairProcStop() { for (var i = 0; i < view.setupProcs.length; i++) view.setupProcs[i].running = false }
      }
    }
  }

  // ======================================================================
  // 3. lights
  // ======================================================================
  Column {
    visible: setup.step === "lights" || setup.step === "saving"
    width: parent.width
    spacing: Style.space(10)

    readonly property var inv: view ? view.inventory : null

    Text {
      textFormat: Text.PlainText
      visible: !parent.inv
      width: parent.width
      text: view && view.setupBusy ? "Reading your lights…" : ""
      color: setup.dim
      font.family: setup.family
      font.pixelSize: Style.font.bodySmall
    }
    Button {
      visible: !parent.inv && !!view && !view.setupBusy
      text: "Try again"
      fontFamily: setup.family
      foreground: setup.fg
      bordered: true
      onClicked: view.loadInventory()
    }

    Text {
      visible: !!parent.inv
      width: parent.width
      wrapMode: Text.WordWrap
      text: "Beat: takes the rhythm, a hit on every beat.  Dynamic: the show decides, drifting, taking turns on the beat and the big moments.  Glow: ambient colour, no beats.  Up to 10 lights stream live (a Hue bridge's limit), so up to 10 can be Beat or Dynamic; extra Glow lights take slow fades. Lights left Off are never touched, and every light goes back to how it was when the music stops."
      textFormat: Text.PlainText
      color: setup.dim
      font.family: setup.family
      font.pixelSize: Style.font.caption
    }

    // Entertainment areas the user already has (from the Hue app or others).
    Flow {
      visible: !!parent.inv && areaRep.count > 0
      width: parent.width
      spacing: Style.space(6)
      Text {
        textFormat: Text.PlainText
        height: Style.space(24)
        verticalAlignment: Text.AlignVCenter
        text: "Use an area you have:"
        color: setup.faint
        font.family: setup.family
        font.pixelSize: Style.font.caption
      }
      Repeater {
        id: areaRep
        model: parent.parent.inv ? parent.parent.inv.areas.filter(function(a) { return a.lights.length > 0 && a.lights.length <= 10 && a.id !== (view.inventory.room || {}).ownArea }) : []
        delegate: Button {
          required property var modelData
          text: modelData.name + " · " + modelData.lights.length
          fontFamily: setup.family
          fontSize: Style.font.caption
          foreground: setup.fg
          bordered: true
          selected: view.chosenArea === modelData.id
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(1)
          tooltipText: "Its lights take the beat, at the places it already has"
          onClicked: view.useArea(modelData)
        }
      }
    }

    Rectangle {
      visible: !!parent.inv
      width: parent.width
      height: Math.min(Math.max(Style.space(300), (view ? view.screenH : 900) - Style.space(420)), list.contentHeight + Style.space(8))
      radius: Style.cornerRadius
      color: Util.alpha(setup.fg, 0.025)
      border.width: 1
      border.color: Util.alpha(setup.fg, 0.08)
      clip: true

      ListView {
        id: list
        anchors.fill: parent
        anchors.margins: Style.space(4)
        boundsBehavior: Flickable.StopAtBounds
        model: {
          var inv = parent.parent.inv
          if (!inv) return []
          var byRoom = {}, order = []
          for (var i = 0; i < inv.lights.length; i++) {
            var l = inv.lights[i]
            var r = l.room || "Not in a room"
            if (!byRoom[r]) { byRoom[r] = []; order.push(r) }
            byRoom[r].push(l)
          }
          var rows = []
          for (var k = 0; k < order.length; k++) {
            rows.push({ head: true, name: order[k] })
            var ls = byRoom[order[k]].slice().sort(function(a, b) { return (b.color ? 1 : 0) - (a.color ? 1 : 0) })
            for (var j = 0; j < ls.length; j++) rows.push(ls[j])
          }
          return rows
        }
        delegate: Item {
          required property var modelData
          width: list.width
          height: modelData.head ? Style.space(26) : Style.space(34)
          Text {
            visible: !!modelData.head
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(3)
            textFormat: Text.PlainText
            text: String(modelData.name).toUpperCase()
            color: setup.faint
            font.family: setup.family
            font.pixelSize: Math.max(8, Style.font.caption - 1)
            font.bold: true
            font.letterSpacing: 1.4
          }
          Item {
            visible: !modelData.head
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(6)
            readonly property bool usable: !!modelData.color && !!modelData.ent
            readonly property string mode: usable && view.choice[modelData.id] ? view.choice[modelData.id] : "off"
            readonly property bool live: !!view.liveSet[modelData.id]
            Rectangle {
              id: dot
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(9)
              height: width
              radius: width / 2
              color: parent.mode !== "off" && parent.live ? Color.accent : "transparent"
              border.width: parent.mode !== "off" && !parent.live ? Math.max(1.5, Style.space(2)) : (parent.mode === "off" ? 1 : 0)
              border.color: parent.mode !== "off" ? Color.accent : Util.alpha(setup.fg, 0.3)
            }
            Text {
              anchors.left: dot.right
              anchors.leftMargin: Style.space(10)
              anchors.right: modes.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: modelData.name + (parent.mode !== "off" && !parent.live ? "  · slow fades" : "")
              color: parent.usable ? setup.fg : setup.faint
              font.family: setup.family
              font.pixelSize: Style.font.bodySmall
            }
            ButtonGroup {
              id: modes
              visible: parent.usable
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              options: [{ value: "beat", label: "Beat", tooltip: "Takes the rhythm: a hit on every beat" },
                        { value: "dynamic", label: "Dynamic", tooltip: "The show decides: drift, turns on the beat, big moments" },
                        { value: "glow", label: "Glow", tooltip: "Ambient colour, no beats" },
                        { value: "off", label: "Off", tooltip: "Never touched" }]
              value: parent.mode
              focusable: false
              foreground: setup.fg
              background: "transparent"
              fontFamily: setup.family
              fontSize: Style.font.caption
              onChanged: function(v) { view.setMode(modelData.id, v) }
            }
            Text {
              textFormat: Text.PlainText
              visible: !parent.usable
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.color ? "can't stream" : "white only"
              color: setup.faint
              font.family: setup.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    Item {
      visible: !!parent.inv
      width: parent.width
      implicitHeight: saveBtn.implicitHeight
      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Button {
          text: "Pair another bridge"
          fontFamily: setup.family
          fontSize: Style.font.caption
          foreground: setup.dim
          tooltipText: "Search again and press a bridge's button; this one stays paired until that succeeds"
          onClicked: { view.setupStep = "find"; view.discover() }
        }
        Button {
          text: "Forget"
          fontFamily: setup.family
          fontSize: Style.font.caption
          foreground: setup.dim
          tooltipText: "Delete psywall's key for this bridge from this computer"
          onClicked: view.forgetBridge()
        }
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: saveBtn.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        text: !view ? "" : view.onCount + " on · " + view.liveCount + " live" + (view.onCount > view.liveCount ? " · " + (view.onCount - view.liveCount) + " slow" : "")
        color: setup.dim
        font.family: setup.family
        font.pixelSize: Style.font.caption
      }
      Button {
        id: saveBtn
        anchors.right: parent.right
        text: setup.step === "saving" ? "Saving…" : "Save and place lights"
        iconSpinning: setup.step === "saving"
        enabled: setup.step !== "saving" && !!view && view.onCount > 0
        opacity: enabled ? 1 : 0.5
        fontFamily: setup.family
        foreground: setup.fg
        bordered: true
        selected: true
        onClicked: view.saveLights()
      }
    }
  }

  component BridgeIcon: Rectangle {
    property real size: 30
    property color fg: "white"
    width: size
    height: size
    radius: size * 0.24
    color: Util.alpha(fg, 0.08)
    border.width: 1
    border.color: Util.alpha(fg, 0.4)
    Rectangle {
      anchors.centerIn: parent
      width: parent.size * 0.38
      height: width
      radius: width / 2
      color: "transparent"
      border.width: 1.5
      border.color: Util.alpha(parent.fg, 0.7)
    }
  }
}
