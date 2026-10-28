export function labNumber(value:string):number|null{
  if(!value.trim())return null;
  const number=Number(value);
  return Number.isInteger(number)&&number>=1&&number<=99?number:null;
}
