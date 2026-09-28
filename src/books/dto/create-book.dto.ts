import { IsInt, IsString, Min, MaxLength , IsNotEmpty} from 'class-validator';

export class CreateBookDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(200)
  title: string;

  @IsString()
  @MaxLength(150)
  author: string;

  @IsInt()
  @Min(1)
  totalCopies: number;
}