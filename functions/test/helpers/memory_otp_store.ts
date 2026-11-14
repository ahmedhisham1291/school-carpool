import type { CodeRecord, LimitRecord, OtpStore, OtpTransaction } from "../../src/auth/otp_flow";

/**
 * In-memory OtpStore for unit tests. Writes are buffered and applied only
 * when the transaction function returns, like Firestore; a throw discards
 * them. It also fails the test if a read follows a write.
 */
export class MemoryOtpStore implements OtpStore {
  readonly limits = new Map<string, LimitRecord>();
  readonly codes = new Map<string, CodeRecord>();
  readonly known = new Map<string, number>();

  async run<T>(fn: (tx: OtpTransaction) => Promise<T>): Promise<T> {
    const writes: Array<() => void> = [];
    let wrote = false;
    const readGuard = () => {
      if (wrote) throw new Error("read after write in a transaction");
    };
    const tx: OtpTransaction = {
      getLimit: async (key) => {
        readGuard();
        const value = this.limits.get(key);
        return value ? { ...value } : undefined;
      },
      getCode: async (key) => {
        readGuard();
        const value = this.codes.get(key);
        return value ? { ...value } : undefined;
      },
      setLimit: (key, record) => {
        wrote = true;
        writes.push(() => this.limits.set(key, { ...record }));
      },
      setCode: (key, record) => {
        wrote = true;
        writes.push(() => this.codes.set(key, { ...record }));
      },
      deleteCode: (key) => {
        wrote = true;
        writes.push(() => this.codes.delete(key));
      },
      getKnownDevice: async (key) => {
        readGuard();
        return this.known.get(key) ?? 0;
      },
      setKnownDevice: (key, untilMs) => {
        wrote = true;
        writes.push(() => this.known.set(key, untilMs));
      },
    };
    const result = await fn(tx);
    for (const write of writes) write();
    return result;
  }
}
