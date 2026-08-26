import QtQuick
import qs.Commons

Rectangle {
  id: btn
  property color fg: "#ffffff"
  property string label: ""
  property string iconFont: ""
  property bool active: false
  signal clicked()

  implicitWidth: txt.implicitWidth + Style.space(20)
  implicitHeight: txt.implicitHeight + Style.space(10)
  radius: Style.cornerRadius
  color: active ? Util.alpha(fg, 0.38)
        : (mouse.pressed ? Util.alpha(fg, 0.30) : Util.alpha(fg, 0.14))
  border.color: active ? Util.alpha(fg, 0.55) : Util.alpha(fg, 0.22)
  border.width: 1

  Text {
    id: txt
    anchors.centerIn: parent
    text: btn.label
    color: fg
    font.family: btn.iconFont !== "" ? btn.iconFont : Style.font.family
    font.pixelSize: Style.font.body
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: btn.clicked()
  }
}
