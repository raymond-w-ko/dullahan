// Error boundary component for catching and displaying runtime errors
// Wraps components to prevent the entire app from crashing

import { Component, type ComponentChildren } from "preact";
import { debug } from "../debug";

interface Props {
  children: ComponentChildren;
  fallback?: (error: Error, reset: () => void) => ComponentChildren;
}

interface State {
  error: Error | null;
}

export class ErrorBoundary extends Component<Props, State> {
  override state: State = { error: null };

  static override getDerivedStateFromError(error: Error): State {
    return { error };
  }

  override componentDidCatch(error: Error, errorInfo: { componentStack?: string }) {
    debug.error("React error boundary caught:", error);
    if (errorInfo.componentStack) {
      debug.error("Component stack:", errorInfo.componentStack);
    }
  }

  reset = () => {
    this.setState({ error: null });
  };

  override render() {
    const { error } = this.state;
    const { children, fallback } = this.props;

    if (error) {
      if (fallback) {
        return fallback(error, this.reset);
      }

      return (
        <div class="error-boundary">
          <div class="error-boundary-content">
            <h2 class="error-boundary-title">Something went wrong</h2>
            <pre class="error-boundary-message">{error.message}</pre>
            {error.stack && (
              <details class="error-boundary-details">
                <summary>Stack trace</summary>
                <pre class="error-boundary-stack">{error.stack}</pre>
              </details>
            )}
            <button class="error-boundary-btn" onClick={this.reset}>
              Try Again
            </button>
          </div>
        </div>
      );
    }

    return children;
  }
}
