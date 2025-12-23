export function validateCName(name: string): boolean {
    return !!name.match(/^[A-Za-z_][A-Za-z0-9_]*$/);
}