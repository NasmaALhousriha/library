import { Body, Controller, Get, Param, ParseIntPipe, Post } from '@nestjs/common';
import { CreateBookDto } from './dto/create-book.dto.js';
import { BooksService } from './books.service.js';

@Controller('books')
export class BooksController {
  constructor(private readonly booksService: BooksService) {}

  // POST /books  
  @Post()
  create(@Body() dto: CreateBookDto) {
    return this.booksService.createBook(dto.title, dto.author, dto.totalCopies);
  }

  // GET /books
  @Get()
  findAll() {
    return this.booksService.listBooks();
  }

  // GET /books/1
  @Get(':id')
  findOne(@Param('id', ParseIntPipe) id: number) {
    return this.booksService.getBookById(id);
  }
}