export function validateCName(name: string): boolean {
    return !!name.match(/^[A-Za-z_][A-Za-z0-9_]*$/);
}
export type CValidatedIdentifierName = string & {__is_c_validated_identifier_name: true};