export type Severity='high'|'medium'|'low';
export interface CspMapping{omaUri:string;dataType:'integer'|'string'|'boolean'|'base64'|'xml';value:string|number|boolean;confidence:'verified'|'suggested'|'unmapped';rationale?:string}
export interface StigRule{id:string;ruleId:string;stigId:string;srgId:string;title:string;severity:Severity;category:string;cci:string[];discussion:string;check:string;fix:string;registry?:{hive:string;path:string;name:string;type:string;value:string};mapping?:CspMapping}
export interface StigDataset{benchmark:{title:string;version:string;release:string;date:string};rules:StigRule[]}
export interface PackagePolicy{id:string;name:string;version:string;category:string;product:string;platform:string;description:string;settings?:number;technology:string;sourceFile:string;fileSize:number}
export interface PackageDataset{package:{name:string;release:string;scope:string;warning:string;guidance:string;knownIssues:string[]};policies:PackagePolicy[]}
export interface PackageAssessment{id:string;purpose:string;recommendation:string;dependencies:string[];risks:string[];confidence:'high'|'medium'|'low'}
