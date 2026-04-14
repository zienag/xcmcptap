import SwiftUI

public struct CardBorder: ViewModifier {
  public var radius: CGFloat
  public func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .strokeBorder(.separator.opacity(SurfaceOpacity.border), lineWidth: BorderWidth.hairline)
    }
  }
}

public struct CardSurface: ViewModifier {
  public var radius: CGFloat
  public func body(content: Content) -> some View {
    content
      .background(
        .background.secondary,
        in: RoundedRectangle(cornerRadius: radius, style: .continuous),
      )
      .modifier(CardBorder(radius: radius))
  }
}

public extension View {
  func cardBorder(radius: CGFloat = Radius.medium) -> some View {
    modifier(CardBorder(radius: radius))
  }

  func cardSurface(radius: CGFloat = Radius.medium) -> some View {
    modifier(CardSurface(radius: radius))
  }
}
