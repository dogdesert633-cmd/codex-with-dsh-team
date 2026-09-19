export function shouldAcceptModelProjection(current, incoming) {
  const incomingRevision = Number.isSafeInteger(incoming?.revision) ? incoming.revision : -1;
  const currentRevision = Number.isSafeInteger(current?.revision) ? current.revision : -1;
  return incomingRevision >= currentRevision;
}

// A missing/unavailable default must never turn into the first provider in the list.
export function modelFormSelection(settings) {
  const selected = settings?.selection ?? settings?.effective ?? settings?.dshDefault;
  const provider = settings?.providers?.find((item) => item.id === selected?.provider);
  const valid = Boolean(provider?.models?.some((item) => item.id === selected?.model));
  return { provider: provider?.id ?? "", model: valid ? selected.model : "", valid };
}
