export function shouldAcceptModelProjection(current, incoming) {
  const incomingRevision = Number.isSafeInteger(incoming?.revision) ? incoming.revision : -1;
  const currentRevision = Number.isSafeInteger(current?.revision) ? current.revision : -1;
  return incomingRevision >= currentRevision;
}
