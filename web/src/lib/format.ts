import { formatUnits } from "viem";

export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
export const fmtAmount = (v: bigint, decimals: number, max = 6) => {
  const s = formatUnits(v, decimals);
  const [i, f = ""] = s.split(".");
  const ft = f.slice(0, max).replace(/0+$/, "");
  return ft ? `${i}.${ft}` : i;
};
export const fmtDate = (sec: bigint | number) =>
  new Date(Number(sec) * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
export function fmtRemaining(sec: number): string {
  if (sec <= 0) return "ended";
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  if (d) return `${d}d ${h}h left`;
  if (h) return `${h}h ${m}m left`;
  return `${Math.max(m, 1)}m left`;
}
export const byteLen = (s: string) => new TextEncoder().encode(s).length;
