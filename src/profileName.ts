export function profileName(value: unknown, metadata: Record<string,unknown> = {}) {
  const candidates = [value, metadata.display_name, metadata.full_name, metadata.name,
    [metadata.first_name, metadata.last_name].filter(v => typeof v === 'string' && v.trim()).join(' ')];
  return candidates.find((v): v is string => typeof v === 'string' && Boolean(v.trim()))?.trim() || '';
}
