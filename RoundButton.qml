import QtQuick
import qs.Commons
import qs.Ui

// Circular icon button with press micro-scale (scale never affects layout).
// Theme-driven: all fills/borders derive from `foreground` so it stays
// coherent with native panels in any theme.
Rectangle {
  id: root

  property string iconText: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property real iconSize: Style.font.title
  property real size: Style.space(48)

  signal clicked()

  width: size
  height: size
  radius: size / 2
  color: mouse.pressed ? Util.alpha(foreground, 0.30)
    : (mouse.containsMouse ? Util.alpha(foreground, 0.22) : Util.alpha(foreground, 0.10))
  border.color: Util.alpha(foreground, mouse.containsMouse ? 0.45 : 0.2)
  border.width: 1
  scale: mouse.pressed ? 0.92 : 1.0

  Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
  Behavior on color { ColorAnimation { duration: 120 } }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.iconText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: root.iconSize
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
  }
}
