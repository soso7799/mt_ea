Option Explicit

' 監聽「儀表板總表」：B5 換商品就自動更新儀表板
Public WithEvents ws As Worksheet

Private Sub ws_Change(ByVal Target As Range)
    If Intersect(Target, ws.Range("B5")) Is Nothing Then Exit Sub
    Application.EnableEvents = False
    On Error Resume Next
    Module1.切換商品
    Application.EnableEvents = True
End Sub
