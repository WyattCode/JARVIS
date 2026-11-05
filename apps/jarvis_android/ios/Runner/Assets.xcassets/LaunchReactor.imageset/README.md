The launch screen's picture: the reactor itself (ReactorView, idle, dark), rendered at 176 pt (1x/2x/3x) so that the system's launch
screen and the app's flying reactor are the same drawing. The name is new on purpose: the system keeps a launch screen's snapshot,
and an image with the old name (LaunchImage) kept showing the old picture. To make it again: draw a ReactorView(frame 176x176,
apply ["mode": "idle", "dark": true]) with layer.render(in:) into a transparent UIGraphicsImageRenderer image at scales 1, 2, 3.
