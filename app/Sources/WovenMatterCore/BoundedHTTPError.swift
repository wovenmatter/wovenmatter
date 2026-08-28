public enum BoundedHTTPError: Error, Equatable {
  case redirectDenied
  case responseTooLarge(maximumBytes: Int)
}
