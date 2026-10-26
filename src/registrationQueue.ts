// Serialize startup/setup and manual registrations, including their dialogs.
// New manual requests invalidate old completion actions, but still run in order.
export class RegistrationQueue {
  private tail: Promise<unknown> = Promise.resolve();
  private pending = 0;
  private revision = 0;
  private manualRequested = false;
  private manualPending = 0;
  private manualRevision = 0;

  get busy() {
    return this.pending > 0;
  }

  get version() {
    return this.revision;
  }

  get hasManualRequest() {
    return this.manualRequested;
  }

  get hasPendingManualRequest() {
    return this.manualPending > 0;
  }

  get manualVersion() {
    return this.manualRevision;
  }

  enqueue<T>(task: (isLatest: () => boolean) => Promise<T>, manual = false) {
    const version = ++this.revision;
    this.manualRequested ||= manual;
    if (manual) {
      this.manualPending += 1;
      this.manualRevision += 1;
    }
    this.pending += 1;

    const result = this.tail
      .then(() => task(() => this.revision === version))
      .finally(() => {
        this.pending -= 1;
        if (manual) this.manualPending -= 1;
      });

    // A failed request must not prevent the next request from running.
    this.tail = result.catch(() => undefined);
    return result;
  }
}
