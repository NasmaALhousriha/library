import { IsInt, IsPositive } from 'class-validator';

export class ReceiveBookDto {
  @IsInt() @IsPositive()
  queueId: number;

  @IsInt() @IsPositive()
  userId: number;
}