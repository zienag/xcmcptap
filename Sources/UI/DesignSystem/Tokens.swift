import SwiftUI

public enum Spacing {
  public static let hairline: CGFloat = 2
  public static let xs: CGFloat = 4
  public static let s: CGFloat = 8
  public static let m: CGFloat = 12
  public static let l: CGFloat = 16
  public static let xl: CGFloat = 24
}

public enum Radius {
  public static let small: CGFloat = 6
  public static let medium: CGFloat = 8
  public static let large: CGFloat = 10
}

public enum IconSize {
  public static let statusDotInner: CGFloat = 8
  public static let statusDotOuter: CGFloat = 10
  public static let statusDotFrame: CGFloat = 14
  public static let listBadge: CGFloat = 22
  public static let tile: CGFloat = 26
}

public enum SidebarWidth {
  public static let primaryMin: CGFloat = 200
  public static let primaryIdeal: CGFloat = 240
  public static let primaryMax: CGFloat = 320
  public static let toolListMin: CGFloat = 240
  public static let toolListIdeal: CGFloat = 280
  public static let toolListMax: CGFloat = 360
}

public enum WindowSize {
  public static let appMinWidth: CGFloat = 680
  public static let appMinHeight: CGFloat = 400
}

public enum SurfaceOpacity {
  public static let hover: Double = 0.04
  public static let tintFill: Double = 0.12
  public static let iconTint: Double = 0.15
  public static let shadow: Double = 0.5
  public static let border: Double = 0.6
  public static let mutedDot: Double = 0.85
}

public enum BorderWidth {
  public static let hairline: CGFloat = 0.5
  public static let ring: CGFloat = 2
}
