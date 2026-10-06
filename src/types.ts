export type Severity='high'|'medium'|'low';
export type AutomationTarget='intune_policy'|'entra_portal'|'m365_portal'|'configuration_management'|'native_api'|'os_native'|'application_configuration'|'cloud_portal'|'local_script'|'manual_only'|'not_applicable';
export interface AutomationPlan{targetType:AutomationTarget;platform:string;controlPlane:string;automationMethod:string;apiEndpoint:string;permissions:string[];artifacts:string[];automationSteps:string[];validationSteps:string[];rollbackSteps:string[];manualSteps:string[];scriptLanguage?:string;scriptExample?:string}
export interface CspMapping extends AutomationPlan{omaUri:string;dataType:'integer'|'string'|'boolean'|'base64'|'xml';value:string|number|boolean;confidence:'verified'|'suggested'|'unmapped';rationale?:string}
export interface StigRule{id:string;ruleId:string;stigId:string;srgId:string;title:string;severity:Severity;category:string;cci:string[];discussion:string;check:string;fix:string;registry?:{hive:string;path:string;name:string;type:string;value:string};mapping?:CspMapping}
export interface StigDataset{benchmark:{title:string;version:string;release:string;date:string};rules:StigRule[]}
export interface PackagePolicy{id:string;name:string;version:string;category:string;product:string;platform:string;description:string;settings?:number;technology:string;sourceFile:string;fileSize:number}
export interface PackageDataset{package:{name:string;release:string;scope:string;warning:string;guidance:string;knownIssues:string[]};policies:PackagePolicy[]}
export interface PackageAssessment extends AutomationPlan{id:string;purpose:string;recommendation:string;dependencies:string[];risks:string[];confidence:'high'|'medium'|'low'}
export type AiProvider='azure'|'openai'|'google';
export interface AiConfig{provider:AiProvider;apiKey:string;endpoint:string;model:string}

export type AppMeta={name:string;version:string;description:string;author:string;contact:string;license:string;repositoryUrl:string};
export type RunMapping=CspMapping&{id:string};
export interface RunRecord{id:string;datasetKey:string;createdAt:string;provider:AiProvider;model:string;durationSec:number;settings?:{templateId:string;strictness:string;depth:string};rules:{id:string;stigId:string;srgId:string;title:string}[];results:RunMapping[]}
