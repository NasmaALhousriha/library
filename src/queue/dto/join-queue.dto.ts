import { IsInt } from 'class-validator';

export class JoinQueueDto {
  @IsInt()
  userId: number;

  @IsInt()
  bookId: number;
}