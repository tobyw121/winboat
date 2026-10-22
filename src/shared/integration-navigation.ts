export const integrationSections = [
    {id:'overview',label:'Overview',icon:'lucide:layout-dashboard',description:'Start Windows and check the connection to your VM.'},
    {id:'sharing',label:'Clipboard & files',icon:'lucide:clipboard-copy',description:'Move text, images and files between Linux and Windows.'},
    {id:'display',label:'Display & audio',icon:'lucide:monitor-speaker',description:'Adjust Local Desktop, audio and mouse input.'},
    {id:'applications',label:'Applications',icon:'lucide:app-window',description:'Save display and compatibility settings for your Windows apps.'},
    {id:'performance',label:'Performance & network',icon:'lucide:gauge',description:'Measure resource use and try reversible VM settings.'},
    {id:'backups',label:'Backups',icon:'lucide:archive-restore',description:'Create snapshots, export Windows disks and manage recovery.'},
    {id:'diagnostics',label:'Diagnostics',icon:'lucide:stethoscope',description:'Check compatibility, investigate graphics issues and manage API access.'},
] as const;
export type IntegrationSection = typeof integrationSections[number]['id'];
