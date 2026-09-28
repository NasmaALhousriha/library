import { Body, Controller, Get, Param, ParseIntPipe, Post } from '@nestjs/common';
import { BorrowBookDto } from './dto/borrow-book.dto.js';
import { BorrowingsService } from './borrowings.service.js';

@Controller('borrowings')
export class BorrowingsController {
  constructor(private readonly borrowingsService: BorrowingsService) {}

  @Post()
  borrow(@Body() dto: BorrowBookDto) {
    return this.borrowingsService.borrowBook(dto.userId, dto.bookId);
  }

  @Post(':id/return')
  returnBook(@Param('id', ParseIntPipe) id: number) {
    return this.borrowingsService.returnBook(id);
  }

  @Get()
  findAll() {
    return this.borrowingsService.listBorrowings();
  }
}
